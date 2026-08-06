import Foundation
import Testing
import CoreGraphics
import ImageIO
import MapKit
import UniformTypeIdentifiers
import GRDB
@testable import FlightBag

/// Collar detection, exercised against a synthetic sheet shaped like a real
/// one: a bowed map area, a white margin, and a legend panel full of colour
/// chips off to one side (the panel is what a real sectional paints over its
/// western neighbour).
@Suite struct ChartCoverageTests {
    private static let zoom = 8
    private static let originTileX = 40
    private static let originTileY = 60
    private static let tilesWide = 6
    private static let tilesHigh = 5
    private static var sheetWidth: Int { tilesWide * 256 }
    private static var sheetHeight: Int { tilesHigh * 256 }
    private static let worldPixels = Double(1 << zoom) * 256

    // Map area of the synthetic sheet, in sheet pixels.
    private static let mapLeft = 400, mapRight = 1400, mapBottom = 1200
    private static func mapTop(atX x: Int) -> Int {
        // Bows up in the middle by 60 px, like a Lambert sheet in Mercator.
        let fraction = Double(x - mapLeft) / Double(mapRight - mapLeft)
        return 260 - Int(60 * sin(.pi * min(max(fraction, 0), 1)))
    }

    private enum Shape { case sheet, seamless }

    private func makeTileSet(_ shape: Shape) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("coverage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Synthetic_sectional.mbtiles")

        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE metadata (name TEXT, value TEXT)")
            try db.execute(sql: """
                CREATE TABLE tiles (
                    zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB
                )
                """)
            try db.execute(sql: "INSERT INTO metadata VALUES ('minzoom', ?), ('maxzoom', ?)",
                           arguments: [String(Self.zoom), String(Self.zoom)])
            let side = (1 << Self.zoom) - 1
            for tileY in 0..<Self.tilesHigh {
                for tileX in 0..<Self.tilesWide {
                    let data = try #require(Self.tilePNG(tileX: tileX, tileY: tileY, shape: shape))
                    try db.execute(
                        sql: "INSERT INTO tiles VALUES (?, ?, ?, ?)",
                        arguments: [
                            Self.zoom,
                            Self.originTileX + tileX,
                            side - (Self.originTileY + tileY),   // MBTiles rows are TMS
                            data,
                        ]
                    )
                }
            }
        }
        return url
    }

    /// One tile of the synthetic sheet.
    private static func tilePNG(tileX: Int, tileY: Int, shape: Shape) -> Data? {
        var pixels = [UInt8](repeating: 0, count: 256 * 256 * 4)
        for y in 0..<256 {
            for x in 0..<256 {
                let sheetX = tileX * 256 + x, sheetY = tileY * 256 + y
                let color = self.color(atX: sheetX, y: sheetY, shape: shape)
                let offset = (y * 256 + x) * 4
                pixels[offset] = color.0
                pixels[offset + 1] = color.1
                pixels[offset + 2] = color.2
                pixels[offset + 3] = color.3
            }
        }
        return png(from: pixels, width: 256, height: 256)
    }

    private static func color(atX x: Int, y: Int, shape: Shape) -> (UInt8, UInt8, UInt8, UInt8) {
        let chartInk: (UInt8, UInt8, UInt8, UInt8) = (198, 168, 116, 255)   // tan: chroma 82
        let paper: (UInt8, UInt8, UInt8, UInt8) = (255, 255, 255, 255)
        func tinted() -> (UInt8, UInt8, UInt8, UInt8) {
            (x / 7 + y / 5) % 3 == 0 ? chartInk : paper
        }
        if shape == .seamless { return tinted() }

        // Off the sheet entirely.
        if x < 40 || x > sheetWidth - 40 || y < 40 || y > sheetHeight - 40 { return (0, 0, 0, 0) }
        // Legend panel: white, with colour chips, separated from the map area
        // by a white gutter.
        if x >= 60, x <= 380, y >= 150, y <= 1150 {
            return (y % 120 < 30 && x % 200 < 60) ? (60, 90, 220, 255) : paper
        }
        guard x >= mapLeft, x <= mapRight, y >= mapTop(atX: x), y <= mapBottom else { return paper }
        // A colourless patch inside the chart — plains and big lakes do this,
        // and the edge tracing has to carry over them.
        if x >= 700, x <= 900, y >= mapTop(atX: x), y <= mapTop(atX: x) + 90 { return paper }
        return tinted()
    }

    private static func png(from pixels: [UInt8], width: Int, height: Int) -> Data? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Sheet pixel x/y ↔ normalized web mercator.
    private static func normalizedX(_ sheetX: Int) -> Double {
        Double(originTileX * 256 + sheetX) / worldPixels
    }
    private static func normalizedY(_ sheetY: Int) -> Double {
        Double(originTileY * 256 + sheetY) / worldPixels
    }
    private static func sheetX(_ normalized: Double) -> Double {
        normalized * worldPixels - Double(originTileX * 256)
    }
    private static func sheetY(_ normalized: Double) -> Double {
        normalized * worldPixels - Double(originTileY * 256)
    }

    // MARK: Detection

    @Test func findsTheMapAreaInsideTheCollar() throws {
        let url = try makeTileSet(.sheet)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let coverage = try #require(ChartCoverageDetector.detect(tileSetAt: url))
        let body = try #require(coverage.body, "the legend panel and margins should read as collar")

        // Within a cell or two of the drawn neatline, and always inside it:
        // leaving collar behind is the failure that matters.
        let tolerance = Double(ChartCoverageDetector.cell * 3)
        let left = Self.sheetX(body.minX), right = Self.sheetX(body.maxX)
        #expect(left >= Double(Self.mapLeft) - 1)
        #expect(left <= Double(Self.mapLeft) + tolerance)
        #expect(right <= Double(Self.mapRight) + 1)
        #expect(right >= Double(Self.mapRight) - tolerance)

        // The legend panel is out — that is the strip that used to cover the
        // neighbouring chart.
        #expect(left > 380)

        let bottom = Self.sheetY(body.bounds.maxY)
        #expect(bottom <= Double(Self.mapBottom) + 1)
        #expect(bottom >= Double(Self.mapBottom) - tolerance)

        // The bowed top edge is followed, not flattened into a rectangle…
        let middleTop = Self.sheetY(body.edges(atX: Self.normalizedX(900)).top)
        let edgeTop = Self.sheetY(body.edges(atX: Self.normalizedX(430)).top)
        #expect(middleTop < edgeTop - 30)
        // …and the colourless patch at x 700–900 did not drag it down.
        #expect(middleTop <= Double(Self.mapTop(atX: 900)) + tolerance)
    }

    @Test func leavesSeamlessTileSetsAlone() throws {
        let url = try makeTileSet(.seamless)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let coverage = try #require(ChartCoverageDetector.detect(tileSetAt: url))
        // open flightmaps ships tiles with no collar; clipping them to where
        // the detector happened to see colour would hide real chart.
        #expect(coverage.body == nil)
        #expect(coverage.extent.minX == Self.normalizedX(0))
    }

    @Test func cachesToASidecarAndReadsItBack() throws {
        let url = try makeTileSet(.sheet)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(ChartCoverageDetector.cached(forTileSet: url) == nil)
        #expect(ChartCoverageDetector.prepare(tileSets: [url]))
        let cached = try #require(ChartCoverageDetector.cached(forTileSet: url))
        #expect(cached.body != nil)
        // Second pass is a no-op: analysis is expensive enough to be worth
        // doing once per download.
        #expect(!ChartCoverageDetector.prepare(tileSets: [url]))

        let sidecar = ChartCoverageDetector.sidecarURL(forTileSet: url)
        var stale = try JSONDecoder().decode(ChartCoverage.self, from: Data(contentsOf: sidecar))
        stale.version = ChartCoverage.currentVersion - 1
        try JSONEncoder().encode(stale).write(to: sidecar)
        #expect(ChartCoverageDetector.cached(forTileSet: url) == nil, "an older detector's answer is not reused")
    }

    // MARK: Tile decisions

    private func mask(top: Double, bottom: Double, fromX: Double, toX: Double) -> ChartCoverage.ColumnMask {
        let step = (toX - fromX) / 8
        return ChartCoverage.ColumnMask(
            originX: fromX + step / 2,
            stepX: step,
            top: Array(repeating: top, count: 8),
            bottom: Array(repeating: bottom, count: 8)
        )
    }

    @Test func classifiesTilesAgainstTheChartBody() {
        let path = MKTileOverlayPath(x: 40, y: 60, z: 8, contentScaleFactor: 1)
        let tile = ChartCoverage.MercatorRect.tile(path)
        let inset = (tile.maxX - tile.minX) / 4

        let covering = ChartCoverage(
            version: ChartCoverage.currentVersion,
            extent: tile,
            body: mask(top: tile.minY - inset, bottom: tile.maxY + inset,
                       fromX: tile.minX - inset, toX: tile.maxX + inset)
        )
        #expect(covering.visibility(ofTile: tile) == .whole)

        let clipping = ChartCoverage(
            version: ChartCoverage.currentVersion,
            extent: tile,
            body: mask(top: tile.minY + inset, bottom: tile.maxY + inset,
                       fromX: tile.minX - inset, toX: tile.maxX + inset)
        )
        #expect(clipping.visibility(ofTile: tile) == .partial)

        let elsewhere = ChartCoverage(
            version: ChartCoverage.currentVersion,
            extent: tile,
            body: mask(top: tile.maxY + inset, bottom: tile.maxY + 2 * inset,
                       fromX: tile.minX, toX: tile.maxX)
        )
        #expect(elsewhere.visibility(ofTile: tile) == .hidden, "collar-only tiles are not drawn at all")

        // No detected body means no clipping: the pre-detection behaviour.
        let unanalysed = ChartCoverage(version: ChartCoverage.currentVersion, extent: tile, body: nil)
        #expect(unanalysed.visibility(ofTile: tile) == .whole)
    }

    @Test func clippingATileErasesOnlyTheCollarSide() throws {
        let path = MKTileOverlayPath(x: 40, y: 60, z: 8, contentScaleFactor: 1)
        let tile = ChartCoverage.MercatorRect.tile(path)
        let height = tile.maxY - tile.minY
        let body = mask(
            top: tile.minY + height / 2, bottom: tile.maxY + height,
            fromX: tile.minX - height, toX: tile.maxX + height
        )
        let solid = try #require(Self.png(
            from: [UInt8](repeating: 255, count: 256 * 256 * 4), width: 256, height: 256
        ))

        let clipped = try #require(ChartTileMask.applying(body, toTile: tile, of: solid))
        let alpha = try Self.alphaSamples(clipped, at: [(128, 40), (128, 200)])
        #expect(alpha[0] == 0, "the half above the neatline is erased")
        #expect(alpha[1] > 200, "the chart half is untouched")
    }

    private static func alphaSamples(_ png: Data, at points: [(Int, Int)]) throws -> [UInt8] {
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        pixels.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return points.map { pixels[($0.1 * image.width + $0.0) * 4 + 3] }
    }
}
