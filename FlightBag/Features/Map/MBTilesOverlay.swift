import Foundation
import MapKit
import GRDB

/// MKTileOverlay that serves tiles straight from a local MBTiles file
/// (which is just SQLite) — fully offline, no embedded tile server.
final class MBTilesOverlay: MKTileOverlay {
    private let dbQueue: DatabaseQueue
    /// Deepest zoom stored in the file; deeper requests are synthesized by
    /// upscaling these tiles (see TileResampler).
    private let nativeMaxZ: Int

    init?(fileURL: URL) {
        var config = Configuration()
        config.readonly = true
        guard let queue = try? DatabaseQueue(path: fileURL.path, configuration: config) else {
            return nil
        }
        dbQueue = queue

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
