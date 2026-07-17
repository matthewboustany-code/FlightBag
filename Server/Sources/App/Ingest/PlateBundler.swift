import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import GRDB
import FBModels

/// Builds a per-region terminal-procedure bundle: every plate PDF for the
/// region's airports, zipped as `{airportId}/{pdfName}` — exactly the layout
/// `PlateStore` uses under `cycles/{cycle}/plates/`, so the app unzips a
/// bundle straight into place and the existing plate UI works unchanged.
///
/// PDFs download from the FAA URLs already recorded in aero.sqlite by
/// d-TPP ingestion, cached per cycle in the work directory so re-runs and
/// overlapping regions don't re-fetch. Zipping shells out to `zip`
/// (present on macOS; install `zip` in the Linux/Docker image).
struct PlateBundler {
    let workDirectory: URL
    let logger: (String) -> Void

    struct PlateRow: Sendable {
        let airportId: String
        let pdfName: String
        let cycle: String
        let url: URL
    }

    /// Plates for every airport in `stateCode`, joined via airport.state.
    static func plateRows(databasePath: String, stateCode: String) throws -> [PlateRow] {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: databasePath, configuration: configuration)
        return try queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT plate.airport_id, plate.pdf_name, plate.cycle, plate.url
                FROM plate JOIN airport ON airport.id = plate.airport_id
                WHERE airport.state = ?
                ORDER BY plate.airport_id, plate.pdf_name
                """, arguments: [stateCode])
            return rows.compactMap { row in
                guard let url = URL(string: row["url"]) else { return nil }
                return PlateRow(airportId: row["airport_id"], pdfName: row["pdf_name"], cycle: row["cycle"], url: url)
            }
        }
    }

    /// The database's own cycle id (meta table), the authoritative cycle for
    /// bundle naming.
    static func databaseCycle(databasePath: String) throws -> String {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: databasePath, configuration: configuration)
        guard let cycle = try queue.read({ db in
            try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'cycle'")
        }) else {
            throw IngestError("aero.sqlite has no cycle in its meta table")
        }
        return cycle
    }

    /// Downloads (with per-cycle caching) and zips the region's plates.
    /// Returns the number of plates bundled.
    func run(regionId: String, databasePath: String, output: String) async throws -> Int {
        guard regionId.hasPrefix("US-"), regionId.count == 5 else {
            throw IngestError("\(regionId) is not a US state region id (expected e.g. US-TX)")
        }
        let stateCode = String(regionId.dropFirst(3))
        let cycle = try Self.databaseCycle(databasePath: databasePath)
        let rows = try Self.plateRows(databasePath: databasePath, stateCode: stateCode)
        guard !rows.isEmpty else {
            throw IngestError("No plates found for \(regionId) — was ingest-dtpp run against this database?")
        }
        logger("\(rows.count) plates for \(regionId), cycle \(cycle)")

        // Staging tree mirrors the zip layout: {stage}/{airportId}/{pdfName}.
        let stage = workDirectory.appendingPathComponent("plates/\(cycle)/\(regionId)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)

        var downloaded = 0
        for (index, row) in rows.enumerated() {
            let target = stage.appendingPathComponent("\(row.airportId)/\(row.pdfName)")
            if !FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                var request = URLRequest(url: row.url)
                request.setValue("Mozilla/5.0 (Macintosh) FlightBag-Ingest/1.0", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw IngestError("Plate download failed (\(row.url.lastPathComponent)): HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                }
                try data.write(to: target)
                downloaded += 1
            }
            if (index + 1) % 25 == 0 || index + 1 == rows.count {
                logger("\(index + 1)/\(rows.count) plates staged")
            }
        }
        logger("\(downloaded) fetched, \(rows.count - downloaded) cached")

        // zip runs from the staging dir, so the output path must be absolute.
        let absoluteOutput = URL(fileURLWithPath: output).standardizedFileURL.path
        try? FileManager.default.removeItem(atPath: absoluteOutput)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: absoluteOutput).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // -X strips extraneous attrs; paths inside the zip are relative to stage.
        try runIngestProcess("/usr/bin/zip", ["-q", "-r", "-X", absoluteOutput, "."], currentDirectory: stage)
        logger("Bundle written to \(output)")
        return rows.count
    }
}
