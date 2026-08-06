import Foundation
import MapKit
import GRDB
import ImageIO
import UniformTypeIdentifiers

/// MKTileOverlay that serves tiles straight from a local MBTiles file
/// (which is just SQLite) — fully offline, no embedded tile server.
///
/// Tiles are cut to the chart's map area when a `ChartCoverage` says where
/// that is: an FAA sheet's collar is opaque paper, and unclipped it hides the
/// neighbouring chart (and anything streamed) wherever two sheets overlap.
final class MBTilesOverlay: MKTileOverlay {
    private let dbQueue: DatabaseQueue
    /// Deepest zoom stored in the file; deeper requests are synthesized by
    /// upscaling these tiles (see TileResampler).
    private let nativeMaxZ: Int
    let coverage: ChartCoverage?

    init?(fileURL: URL, coverage: ChartCoverage? = nil) {
        var config = Configuration()
        config.readonly = true
        guard let queue = try? DatabaseQueue(path: fileURL.path, configuration: config) else {
            return nil
        }
        dbQueue = queue
        self.coverage = coverage

        var meta: [String: String] = [:]
        if let metadata = try? queue.read({ db in
            try Row.fetchAll(db, sql: "SELECT name, value FROM metadata")
        }) {
            for row in metadata { meta[row["name"]] = row["value"] }
        }
        // Not all producers write maxzoom metadata; fall back to the data.
        nativeMaxZ = meta["maxzoom"].flatMap(Int.init)
            ?? (try? queue.read { db in try Int.fetchOne(db, sql: "SELECT MAX(zoom_level) FROM tiles") })
            .flatMap { $0 }
            ?? 21

        super.init(urlTemplate: nil)
        tileSize = CGSize(width: 256, height: 256)
        canReplaceMapContent = false
        minimumZ = meta["minzoom"].flatMap(Int.init) ?? 0
    }

    nonisolated override func loadTile(at path: MKTileOverlayPath, result: @escaping @Sendable (Data?, Error?) -> Void) {
        let body = coverage?.body
        let visibility = coverage?.visibility(ofTile: .tile(path)) ?? .whole
        guard visibility != .hidden else {
            result(nil, nil)
            return
        }
        fetch(at: path) { data, error in
            guard let data else {
                result(nil, error)
                return
            }
            guard visibility == .partial, let body else {
                result(data, nil)
                return
            }
            // Falling back to the unclipped tile beats a hole in the chart if
            // the mask cannot be applied for some reason.
            result(ChartTileMask.applying(body, toTile: .tile(path), of: data) ?? data, nil)
        }
    }

    /// The stored tile, or one synthesized from its parent past the file's
    /// deepest zoom.
    private nonisolated func fetch(at path: MKTileOverlayPath, result: @escaping @Sendable (Data?, Error?) -> Void) {
        guard path.z > nativeMaxZ else {
            fetchStored(at: path, result: result)
            return
        }
        let parent = TileResampler.parent(of: path, nativeMaxZ: nativeMaxZ)
        fetchStored(at: parent) { data, error in
            guard let data else {
                result(nil, error)
                return
            }
            result(TileResampler.upscaledQuadrant(parentTile: data, for: path, parent: parent), nil)
        }
    }

    private nonisolated func fetchStored(at path: MKTileOverlayPath, result: @escaping @Sendable (Data?, Error?) -> Void) {
        // MBTiles stores rows in TMS scheme: y grows south-to-north.
        let tmsY = (1 << path.z) - 1 - path.y
        dbQueue.asyncRead { dbResult in
            var data: Data?
            if case .success(let db) = dbResult {
                data = try? Data.fetchOne(
                    db,
                    sql: "SELECT tile_data FROM tiles WHERE zoom_level = ? AND tile_column = ? AND tile_row = ?",
                    arguments: [path.z, path.x, tmsY]
                )
            }
            result(data, nil)
        }
    }
}

nonisolated extension ChartCoverage.MercatorRect {
    /// The normalized Web-Mercator rect a tile path covers.
    static func tile(_ path: MKTileOverlayPath) -> Self {
        let side = Double(1 << path.z)
        return Self(
            minX: Double(path.x) / side,
            minY: Double(path.y) / side,
            maxX: Double(path.x + 1) / side,
            maxY: Double(path.y + 1) / side
        )
    }
}

nonisolated extension ChartCoverage {
    enum TileVisibility { case hidden, whole, partial }

    /// True when this chart paints every pixel of a tile, so streaming the
    /// same tile underneath it would be spent data. Deliberately strict:
    /// the bowed corners of a sheet are inside its extent but outside its
    /// map area, and those are exactly the places streaming should fill.
    func fullyPaints(_ rect: MercatorRect) -> Bool {
        extent.contains(rect) && visibility(ofTile: rect) == .whole
    }

    /// Whether a tile is all chart, all collar, or straddles the neatline.
    func visibility(ofTile rect: MercatorRect) -> TileVisibility {
        guard let body else { return .whole }
        guard let extremes = body.extremes(fromX: rect.minX, toX: rect.maxX) else { return .hidden }
        if extremes.outerBottom <= rect.minY || extremes.outerTop >= rect.maxY { return .hidden }
        let insideHorizontally = body.minX <= rect.minX && body.maxX >= rect.maxX
        if insideHorizontally, extremes.innerTop <= rect.minY, extremes.innerBottom >= rect.maxY {
            return .whole
        }
        return .partial
    }
}

nonisolated extension ChartCoverage.ColumnMask {
    /// Widest and narrowest vertical extent of the map area over an x range;
    /// nil when the range misses the chart entirely.
    func extremes(fromX: Double, toX: Double) -> (
        outerTop: Double, outerBottom: Double, innerTop: Double, innerBottom: Double
    )? {
        guard toX > minX, fromX < maxX, !top.isEmpty else { return nil }
        let first = min(max(0, Int(((fromX - originX) / stepX).rounded(.down))), top.count - 1)
        let last = min(max(0, Int(((toX - originX) / stepX).rounded(.up))), top.count - 1)
        var outerTop = Double.greatestFiniteMagnitude, innerTop = -Double.greatestFiniteMagnitude
        var outerBottom = -Double.greatestFiniteMagnitude, innerBottom = Double.greatestFiniteMagnitude
        for index in first...last {
            outerTop = min(outerTop, top[index]); innerTop = max(innerTop, top[index])
            outerBottom = max(outerBottom, bottom[index]); innerBottom = min(innerBottom, bottom[index])
        }
        return (outerTop, outerBottom, innerTop, innerBottom)
    }

    /// x positions to trace the edges at across a tile: every sample the tile
    /// overlaps, plus the tile's own edges so the polygon closes on them.
    func tracePositions(fromX: Double, toX: Double) -> [Double] {
        let start = max(fromX, minX), end = min(toX, maxX)
        guard end > start else { return [] }
        var positions = [start]
        let firstSample = Int(((start - originX) / stepX).rounded(.up))
        let lastSample = Int(((end - originX) / stepX).rounded(.down))
        if firstSample <= lastSample {
            for index in firstSample...lastSample {
                let x = originX + Double(index) * stepX
                if x > start, x < end { positions.append(x) }
            }
        }
        positions.append(end)
        return positions
    }
}

/// Cuts a tile down to the chart's map area.
nonisolated enum ChartTileMask {
    /// Redraws `data` with everything outside the chart body erased, or nil
    /// if the tile cannot be decoded or re-encoded.
    static func applying(
        _ body: ChartCoverage.ColumnMask,
        toTile rect: ChartCoverage.MercatorRect,
        of data: Data
    ) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }

        let positions = body.tracePositions(fromX: rect.minX, toX: rect.maxX)
        guard positions.count >= 2 else { return nil }
        let spanX = rect.maxX - rect.minX, spanY = rect.maxY - rect.minY
        // Bitmap contexts put the origin bottom-left, and so does the image
        // once drawn: mercator y grows south, so it flips here.
        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(
                x: (x - rect.minX) / spanX * Double(width),
                y: (1 - (y - rect.minY) / spanY) * Double(height)
            )
        }
        let path = CGMutablePath()
        path.move(to: point(positions[0], body.edges(atX: positions[0]).top))
        for x in positions.dropFirst() { path.addLine(to: point(x, body.edges(atX: x).top)) }
        for x in positions.reversed() { path.addLine(to: point(x, body.edges(atX: x).bottom)) }
        path.closeSubpath()

        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.addPath(path)
        context.clip()
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let clipped = context.makeImage() else { return nil }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, clipped, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return encoded as Data
    }
}
