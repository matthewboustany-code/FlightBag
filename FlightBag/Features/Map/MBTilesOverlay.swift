import Foundation
import MapKit
import GRDB

/// MKTileOverlay that serves tiles straight from a local MBTiles file
/// (which is just SQLite) — fully offline, no embedded tile server.
final class MBTilesOverlay: MKTileOverlay {
    private let dbQueue: DatabaseQueue

    init?(fileURL: URL) {
        var config = Configuration()
        config.readonly = true
        guard let queue = try? DatabaseQueue(path: fileURL.path, configuration: config) else {
            return nil
        }
        dbQueue = queue
        super.init(urlTemplate: nil)
        tileSize = CGSize(width: 256, height: 256)
        canReplaceMapContent = false

        if let metadata = try? queue.read({ db in
            try Row.fetchAll(db, sql: "SELECT name, value FROM metadata")
        }) {
            var meta: [String: String] = [:]
            for row in metadata { meta[row["name"]] = row["value"] }
            minimumZ = meta["minzoom"].flatMap(Int.init) ?? 0
            maximumZ = meta["maxzoom"].flatMap(Int.init) ?? 21
        }
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping @Sendable (Data?, Error?) -> Void) {
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
