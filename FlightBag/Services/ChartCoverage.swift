import Foundation
import CoreGraphics
import ImageIO
import GRDB

/// Where a downloaded tile set actually draws chart, in normalized Web
/// Mercator (0…1 from the world's top-left corner).
///
/// FAA rasters are whole printed sheets: the map area sits inside a collar
/// carrying the title block, the legend, and a column of notes over a degree
/// of longitude wide. Tiled as-is that collar is opaque white paint sitting on
/// top of the *neighbouring* chart's map area — which is why a downloaded
/// sectional used to blank out a strip of the chart beside it, permanently.
/// `body` is the map area worth keeping; the rest of the file is collar.
nonisolated struct ChartCoverage: Codable, Sendable, Hashable {
    /// Bump when the detector changes, so cached sidecars are recomputed.
    static let currentVersion = 1

    var version: Int
    /// The whole file's tile extent — everything it could paint unclipped.
    var extent: MercatorRect
    /// The map area, sampled column by column. nil when the tile set has no
    /// detectable collar (open flightmaps ships seamless tiles), in which case
    /// nothing is clipped and `extent` is the coverage.
    var body: ColumnMask?

    /// Rect in normalized Web Mercator; y grows south, matching tile order.
    struct MercatorRect: Codable, Sendable, Hashable {
        var minX: Double
        var minY: Double
        var maxX: Double
        var maxY: Double

        func contains(_ other: MercatorRect) -> Bool {
            other.minX >= minX && other.maxX <= maxX && other.minY >= minY && other.maxY <= maxY
        }
    }

    /// The map area as top and bottom edges sampled at even x steps.
    ///
    /// A rectangle would not do: the sheet is a rectangle in the chart's
    /// Lambert Conformal projection, so in Web Mercator its neatline bows —
    /// by ~25 km between the middle and the corners of a sectional. Sampled
    /// edges follow the bow, and any irregularly shaped sheet, and
    /// interpolate smoothly in between.
    struct ColumnMask: Codable, Sendable, Hashable {
        /// x of the first sample's centre, and the spacing between samples.
        var originX: Double
        var stepX: Double
        /// Top and bottom edge y at each sample, north-to-south.
        var top: [Double]
        var bottom: [Double]

        var minX: Double { originX - stepX / 2 }
        var maxX: Double { originX + (Double(top.count) - 0.5) * stepX }

        /// Bounding box of the map area — the coverage a chart really claims.
        var bounds: MercatorRect {
            MercatorRect(minX: minX, minY: top.min() ?? 0, maxX: maxX, maxY: bottom.max() ?? 0)
        }

        /// Edge y values interpolated at an arbitrary x, clamped at the ends.
        func edges(atX x: Double) -> (top: Double, bottom: Double) {
            let position = (x - originX) / stepX
            let index = Int(position.rounded(.down))
            let fraction = position - Double(index)
            let low = min(max(index, 0), top.count - 1)
            let high = min(max(index + 1, 0), top.count - 1)
            return (
                top[low] + (top[high] - top[low]) * fraction,
                bottom[low] + (bottom[high] - bottom[low]) * fraction
            )
        }

    }
}

/// Finds a chart's map area inside its collar, from the tiles themselves.
///
/// On the device rather than in the tile pipeline, because it has to work for
/// charts already downloaded and for MBTiles sideloaded from anywhere — and
/// because re-cutting what the server has already published would mean every
/// user downloading every chart again.
nonisolated enum ChartCoverageDetector {
    /// Analysis cell, in pixels of the zoom level being read. The detected
    /// edge is only as precise as one cell (~4 km at z8).
    static let cell = 8
    /// Fraction of a cell that must be coloured to seed the chart body…
    private static let seedChroma = 0.12
    /// …and to grow into it. The gap between the two keeps the legend panel
    /// out: it is full of colour chips, but a white gutter separates it from
    /// the map area and growth cannot cross white.
    private static let growChroma = 0.02
    /// Tiles to read for one analysis. A sectional needs 48 at z8.
    private static let tileBudget = 96
    /// Rolling window, in cells, used to bridge colourless stretches inside
    /// the chart (plains, large lakes) when tracing an edge.
    private static let smoothingWindow = 10
    /// Cells trimmed off every edge. Charts overlap their neighbours by tens
    /// of kilometres, so giving up ~7 km of chart costs nothing visible,
    /// while keeping a sliver of collar paints a white seam over the next
    /// chart — which is the whole problem being solved here.
    private static let insetCells = 2

    static func sidecarURL(forTileSet url: URL) -> URL {
        url.appendingPathExtension("coverage")
    }

    /// Cached coverage for a tile set, if it has been analysed.
    static func cached(forTileSet url: URL) -> ChartCoverage? {
        guard let data = try? Data(contentsOf: sidecarURL(forTileSet: url)),
              let coverage = try? JSONDecoder().decode(ChartCoverage.self, from: data),
              coverage.version == ChartCoverage.currentVersion
        else { return nil }
        return coverage
    }

    /// Analyse anything not analysed yet, writing one sidecar per tile set.
    /// Returns true when something was written, so the caller can re-scan.
    @discardableResult
    static func prepare(tileSets urls: [URL]) -> Bool {
        var wrote = false
        for url in urls where cached(forTileSet: url) == nil {
            guard let coverage = detect(tileSetAt: url),
                  let data = try? JSONEncoder().encode(coverage) else { continue }
            try? data.write(to: sidecarURL(forTileSet: url), options: .atomic)
            wrote = true
        }
        return wrote
    }

    /// Read one tile set and work out which part of it is chart.
    static func detect(tileSetAt url: URL) -> ChartCoverage? {
        var config = Configuration()
        config.readonly = true
        guard let queue = try? DatabaseQueue(path: url.path, configuration: config) else { return nil }
        let sample: Sample? = try? queue.read { db in
            guard let zoom = analysisZoom(db) else { return nil }
            return try readTiles(db, zoom: zoom)
        }
        guard let sample else { return nil }

        return ChartCoverage(
            version: ChartCoverage.currentVersion,
            extent: ChartCoverage.MercatorRect(
                minX: Double(sample.minTileX) / sample.worldTiles,
                minY: Double(sample.minTileY) / sample.worldTiles,
                maxX: Double(sample.maxTileX + 1) / sample.worldTiles,
                maxY: Double(sample.maxTileY + 1) / sample.worldTiles
            ),
            body: mapArea(in: sample)
        )
    }

    // MARK: Reading

    /// The deepest zoom cheap enough to analyse, or the shallowest stored one
    /// when even that exceeds the budget.
    private static func analysisZoom(_ db: Database) -> Int? {
        let counts = (try? Row.fetchAll(
            db, sql: "SELECT zoom_level AS z, COUNT(*) AS n FROM tiles GROUP BY zoom_level ORDER BY zoom_level"
        )) ?? []
        guard let shallowest = counts.first else { return nil }
        let affordable = counts.last { ($0["n"] as Int) <= tileBudget }
        return (affordable ?? shallowest)["z"] as Int
    }

    /// Per-cell colour statistics over one zoom level of a tile set.
    private struct Sample {
        var chroma: [Int32]     // coloured pixels per cell
        var opaque: [Int32]
        var white: [Int32]
        var gridWidth: Int
        var gridHeight: Int
        var minTileX: Int
        var minTileY: Int
        var maxTileX: Int
        var maxTileY: Int
        var zoom: Int
        var worldTiles: Double { Double(1 << zoom) }
        var worldPixels: Double { worldTiles * 256 }
    }

    private static func readTiles(_ db: Database, zoom: Int) throws -> Sample? {
        let bounds = try Row.fetchOne(db, sql: """
            SELECT MIN(tile_column) AS minX, MAX(tile_column) AS maxX,
                   MIN(tile_row) AS minRow, MAX(tile_row) AS maxRow
            FROM tiles WHERE zoom_level = ?
            """, arguments: [zoom])
        guard let bounds,
              let minX = bounds["minX"] as Int?, let maxX = bounds["maxX"] as Int?,
              let minRow = bounds["minRow"] as Int?, let maxRow = bounds["maxRow"] as Int?
        else { return nil }

        // MBTiles rows are TMS (y grows north); tile paths are XYZ.
        let side = (1 << zoom) - 1
        let minY = side - maxRow
        let maxY = side - minRow
        let gridWidth = (maxX - minX + 1) * 256 / cell
        let gridHeight = (maxY - minY + 1) * 256 / cell
        var sample = Sample(
            chroma: .init(repeating: 0, count: gridWidth * gridHeight),
            opaque: .init(repeating: 0, count: gridWidth * gridHeight),
            white: .init(repeating: 0, count: gridWidth * gridHeight),
            gridWidth: gridWidth, gridHeight: gridHeight,
            minTileX: minX, minTileY: minY, maxTileX: maxX, maxTileY: maxY,
            zoom: zoom
        )

        var pixels = [UInt8](repeating: 0, count: 256 * 256 * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let rows = try Row.fetchCursor(
            db, sql: "SELECT tile_column, tile_row, tile_data FROM tiles WHERE zoom_level = ?",
            arguments: [zoom]
        )
        while let row = try rows.next() {
            let column: Int = row["tile_column"]
            let tmsRow: Int = row["tile_row"]
            guard let data: Data = row["tile_data"], let image = decode(data) else { continue }
            pixels.withUnsafeMutableBytes { raw in
                guard let context = CGContext(
                    data: raw.baseAddress, width: 256, height: 256, bitsPerComponent: 8,
                    bytesPerRow: 256 * 4, space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return }
                context.clear(CGRect(x: 0, y: 0, width: 256, height: 256))
                context.draw(image, in: CGRect(x: 0, y: 0, width: 256, height: 256))
            }
            accumulate(
                pixels: pixels,
                originX: (column - minX) * 256,
                originY: ((side - tmsRow) - minY) * 256,
                into: &sample
            )
        }
        return sample
    }

    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Classify one tile's pixels into the cell grid. Colour is the signal:
    /// a chart body carries tinted terrain, airspace and water nearly
    /// everywhere, while a collar is black text on white paper.
    private static func accumulate(pixels: [UInt8], originX: Int, originY: Int, into sample: inout Sample) {
        for y in 0..<256 {
            let gridY = (originY + y) / cell
            guard gridY >= 0, gridY < sample.gridHeight else { continue }
            let rowBase = y * 256 * 4
            for x in 0..<256 {
                let offset = rowBase + x * 4
                guard pixels[offset + 3] >= 32 else { continue }
                let gridX = (originX + x) / cell
                guard gridX >= 0, gridX < sample.gridWidth else { continue }
                let index = gridY * sample.gridWidth + gridX
                sample.opaque[index] += 1
                let red = pixels[offset], green = pixels[offset + 1], blue = pixels[offset + 2]
                let high = max(red, max(green, blue))
                let low = min(red, min(green, blue))
                if high - low > 30 {
                    sample.chroma[index] += 1
                } else if low >= 244 {
                    sample.white[index] += 1
                }
            }
        }
    }

    // MARK: Detection

    private static func mapArea(in sample: Sample) -> ChartCoverage.ColumnMask? {
        let perCell = Double(cell * cell)
        let component = grownBody(
            in: sample,
            seed: Int32((seedChroma * perCell).rounded(.up)),
            grow: Int32((growChroma * perCell).rounded(.up))
        )
        guard !component.isEmpty else { return nil }

        var spans: [Int: (top: Int, bottom: Int)] = [:]
        for index in component {
            let x = index % sample.gridWidth, y = index / sample.gridWidth
            let existing = spans[x] ?? (y, y)
            spans[x] = (min(existing.top, y), max(existing.bottom, y))
        }
        // Columns holding a sliver of the typical span are legend chips the
        // growth happened to reach, not chart body.
        let heights = spans.values.map { $0.bottom - $0.top }.sorted()
        let typical = heights[heights.count / 2]
        let solid = spans.keys.filter { spans[$0]!.bottom - spans[$0]!.top >= typical / 2 }.sorted()
        guard solid.count > 4 * insetCells else { return nil }
        let columns = Array(solid.dropFirst(insetCells).dropLast(insetCells))

        let tops = smoothed(columns.map { spans[$0]!.top }, towards: min)
        let bottoms = smoothed(columns.map { spans[$0]!.bottom }, towards: max)
        guard collarLooksLikeCollar(sample: sample, columns: columns, tops: tops, bottoms: bottoms) else {
            return nil
        }

        let mask = ChartCoverage.ColumnMask(
            originX: (Double(sample.minTileX * 256 + columns[0] * cell) + Double(cell) / 2)
                / sample.worldPixels,
            stepX: Double(cell) / sample.worldPixels,
            top: tops.map { normalizedY($0 + insetCells, sample) },
            bottom: bottoms.map { normalizedY($0 + 1 - insetCells, sample) }
        )

        // A tile set with no collar — a seamless set, or a sheet whose body
        // fills the file — must not be clipped at all.
        let bodyArea = zip(mask.top, mask.bottom).reduce(0.0) { $0 + ($1.1 - $1.0) } * mask.stepX
        let extentArea = Double(sample.maxTileX - sample.minTileX + 1)
            * Double(sample.maxTileY - sample.minTileY + 1) / (sample.worldTiles * sample.worldTiles)
        guard bodyArea > 0.2 * extentArea, bodyArea < 0.94 * extentArea else { return nil }
        return mask
    }

    private static func normalizedY(_ gridY: Int, _ sample: Sample) -> Double {
        Double(sample.minTileY * 256 + gridY * cell) / sample.worldPixels
    }

    /// Hysteresis region-growing: start from cells that are unambiguously
    /// chart, spread through any cell with a trace of colour, keep the
    /// largest result.
    private static func grownBody(in sample: Sample, seed: Int32, grow: Int32) -> [Int] {
        let count = sample.gridWidth * sample.gridHeight
        var visited = [Bool](repeating: false, count: count)
        var best: [Int] = []
        var queue: [Int] = []
        for start in 0..<count where sample.chroma[start] >= seed && !visited[start] {
            queue.removeAll(keepingCapacity: true)
            queue.append(start)
            visited[start] = true
            var head = 0
            while head < queue.count {
                let index = queue[head]; head += 1
                let x = index % sample.gridWidth, y = index / sample.gridWidth
                if x > 0 { visit(index - 1, &queue, &visited, sample, grow) }
                if x < sample.gridWidth - 1 { visit(index + 1, &queue, &visited, sample, grow) }
                if y > 0 { visit(index - sample.gridWidth, &queue, &visited, sample, grow) }
                if y < sample.gridHeight - 1 { visit(index + sample.gridWidth, &queue, &visited, sample, grow) }
            }
            if queue.count > best.count { best = queue }
        }
        return best
    }

    private static func visit(
        _ index: Int, _ queue: inout [Int], _ visited: inout [Bool], _ sample: Sample, _ grow: Int32
    ) {
        guard !visited[index], sample.chroma[index] >= grow else { return }
        visited[index] = true
        queue.append(index)
    }

    /// Rolling outward extreme, then a median, over ±`smoothingWindow`
    /// columns. Inside a chart there are stretches with too little colour to
    /// read as body; the rolling pass carries the edge over them, and the
    /// median drops the spikes that pass leaves behind.
    private static func smoothed(_ values: [Int], towards extreme: (Int, Int) -> Int) -> [Int] {
        let rolled = values.indices.map { index -> Int in
            let low = max(0, index - smoothingWindow)
            let high = min(values.count - 1, index + smoothingWindow)
            return values[low...high].reduce(values[index], extreme)
        }
        return rolled.indices.map { index -> Int in
            let low = max(0, index - smoothingWindow)
            let high = min(rolled.count - 1, index + smoothingWindow)
            let sorted = rolled[low...high].sorted()
            return sorted[sorted.count / 2]
        }
    }

    /// Is what we are about to clip away actually a collar? White paper, or
    /// nothing at all, says yes. Anything else means the detection wandered,
    /// and clipping would hide real chart.
    private static func collarLooksLikeCollar(
        sample: Sample, columns: [Int], tops: [Int], bottoms: [Int]
    ) -> Bool {
        var spans: [Int: (top: Int, bottom: Int)] = [:]
        for (offset, column) in columns.enumerated() { spans[column] = (tops[offset], bottoms[offset]) }
        var white: Int64 = 0, opaque: Int64 = 0
        for index in 0..<(sample.gridWidth * sample.gridHeight) {
            let x = index % sample.gridWidth, y = index / sample.gridWidth
            if let span = spans[x], y >= span.top, y <= span.bottom { continue }
            opaque += Int64(sample.opaque[index])
            white += Int64(sample.white[index])
        }
        // Nothing opaque outside the body: the file is already seamless.
        guard opaque > 0 else { return false }
        return Double(white) / Double(opaque) > 0.4
    }
}
