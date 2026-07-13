import Foundation
import GRDB
import FBModels

/// Read-only access to the per-cycle aviation database (`aero.sqlite`) built
/// by the server ingestion pipeline. A bundled seed copy ships with the app;
/// downloaded cycle updates land in the same directory layout and win by
/// being newer.
final class AeroDatabase: Sendable {
    private let dbQueue: DatabaseQueue
    let cycle: DataCycle?

    /// Opens the newest available database, installing the bundled seed into
    /// Application Support on first launch.
    static func open() throws -> AeroDatabase {
        let fileManager = FileManager.default
        let cyclesRoot = try fileManager
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("FlightBag/cycles", isDirectory: true)
        try fileManager.createDirectory(at: cyclesRoot, withIntermediateDirectories: true)

        // Newest cycle directory containing an aero.sqlite wins.
        let installed = ((try? fileManager.contentsOfDirectory(atPath: cyclesRoot.path)) ?? [])
            .filter { fileManager.fileExists(atPath: cyclesRoot.appendingPathComponent("\($0)/aero.sqlite").path) }
            .sorted()

        if let newest = installed.last {
            return try AeroDatabase(path: cyclesRoot.appendingPathComponent("\(newest)/aero.sqlite").path)
        }

        guard let seed = Bundle.main.url(forResource: "aero", withExtension: "sqlite") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Bundled aero.sqlite missing"])
        }
        // Read the seed's cycle so it installs into the right directory.
        let seedDB = try AeroDatabase(path: seed.path)
        let cycleId = seedDB.cycle?.id ?? "seed"
        let target = cyclesRoot.appendingPathComponent("\(cycleId)", isDirectory: true)
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        let targetDB = target.appendingPathComponent("aero.sqlite")
        try? fileManager.removeItem(at: targetDB)
        try fileManager.copyItem(at: seed, to: targetDB)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableTarget = targetDB
        try? mutableTarget.setResourceValues(values)
        return try AeroDatabase(path: targetDB.path)
    }

    init(path: String) throws {
        var config = Configuration()
        config.readonly = true
        dbQueue = try DatabaseQueue(path: path, configuration: config)
        cycle = try dbQueue.read { db in
            (try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'cycle'"))
                .flatMap(DataCycle.init(id:))
        }
    }

    // MARK: Search

    struct SearchResult: Identifiable, Sendable, Hashable {
        let id: String
        let icaoId: String?
        let name: String
        let city: String?
        let state: String?

        var displayIdentifier: String { icaoId ?? id }
    }

    func search(_ text: String, limit: Int = 50) async throws -> [SearchResult] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        // Prefix-match every token so "aust berg" finds Austin-Bergstrom.
        let ftsQuery = trimmed
            .split(separator: " ")
            .map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }
            .joined(separator: " ")
        let exact = trimmed.uppercased()

        return try await dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT a.id, a.icao_id, a.name, a.city, a.state
                FROM airport_fts f
                JOIN airport a ON a.id = f.airport_id
                WHERE airport_fts MATCH ?
                ORDER BY
                    CASE WHEN a.id = ? OR a.icao_id = ? THEN 0 ELSE 1 END,
                    CASE a.site_type WHEN 'A' THEN 0 ELSE 1 END,
                    rank
                LIMIT ?
                """,
                arguments: [ftsQuery, exact, exact, limit]
            ).map { row in
                SearchResult(id: row["id"], icaoId: row["icao_id"], name: row["name"], city: row["city"], state: row["state"])
            }
        }
    }

    func airportsNear(latitude: Double, longitude: Double, spanDegrees: Double = 1.0, limit: Int = 50) async throws -> [SearchResult] {
        try await dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT a.id, a.icao_id, a.name, a.city, a.state
                FROM airport_rtree r
                JOIN airport a ON a.rowid = r.id
                WHERE r.min_lat >= ? AND r.max_lat <= ? AND r.min_lon >= ? AND r.max_lon <= ?
                ORDER BY (a.lat - ?) * (a.lat - ?) + (a.lon - ?) * (a.lon - ?)
                LIMIT ?
                """,
                arguments: [
                    latitude - spanDegrees, latitude + spanDegrees,
                    longitude - spanDegrees, longitude + spanDegrees,
                    latitude, latitude, longitude, longitude,
                    limit,
                ]
            ).map { row in
                SearchResult(id: row["id"], icaoId: row["icao_id"], name: row["name"], city: row["city"], state: row["state"])
            }
        }
    }

    // MARK: Airport detail

    struct AirportDetail: Sendable {
        var airport: Airport
        var plates: [PlateMetadata]
        var trafficPatternAltitude: Double?
        var siteType: String?
        var facilityUse: String?
    }

    func airportDetail(id: String) async throws -> AirportDetail? {
        try await dbQueue.read { db in
            guard let airportRow = try Row.fetchOne(db, sql: "SELECT rowid, * FROM airport WHERE id = ? OR icao_id = ?", arguments: [id, id]) else {
                return nil
            }
            let airportId: String = airportRow["id"]

            let runwayRows = try Row.fetchAll(db, sql: "SELECT * FROM runway WHERE airport_id = ? ORDER BY designator", arguments: [airportId])
            let endRows = try Row.fetchAll(db, sql: "SELECT * FROM runway_end WHERE airport_id = ?", arguments: [airportId])
            let endsByRunway = Dictionary(grouping: endRows) { $0["runway_designator"] as String }

            let runways: [Runway] = runwayRows.map { row in
                let designator: String = row["designator"]
                let ends = (endsByRunway[designator] ?? []).map { end in
                    RunwayEnd(
                        designator: end["designator"],
                        trueHeading: end["true_heading"],
                        coordinate: (end["lat"] as Double?).flatMap { lat in
                            (end["lon"] as Double?).map { Coordinate(latitude: lat, longitude: $0) }
                        },
                        elevationFeet: end["elevation_ft"],
                        displacedThresholdFeet: end["displaced_threshold_ft"]
                    )
                }
                return Runway(
                    designator: designator,
                    lengthFeet: row["length_ft"],
                    widthFeet: row["width_ft"],
                    surface: row["surface"],
                    ends: ends
                )
            }

            let frequencies: [Frequency] = try Row.fetchAll(
                db,
                sql: "SELECT * FROM frequency WHERE airport_id = ? ORDER BY use, freq_khz",
                arguments: [airportId]
            ).map { row in
                Frequency(use: row["use"] ?? "—", kHz: row["freq_khz"], remarks: row["call"])
            }

            let plates: [PlateMetadata] = try Row.fetchAll(
                db,
                sql: "SELECT * FROM plate WHERE airport_id = ? ORDER BY chart_code, chart_name",
                arguments: [airportId]
            ).map { row in
                let pdfName: String = row["pdf_name"]
                return PlateMetadata(
                    id: pdfName,
                    airportId: airportId,
                    chartCode: row["chart_code"],
                    chartName: row["chart_name"],
                    pdfName: pdfName,
                    url: (row["url"] as String?).flatMap(URL.init(string:)),
                    cycle: row["cycle"]
                )
            }

            let airport = Airport(
                id: airportId,
                icaoId: (airportRow["icao_id"] as String?).map { ICAOIdentifier($0) },
                name: airportRow["name"],
                city: airportRow["city"],
                state: airportRow["state"],
                country: airportRow["country"],
                coordinate: Coordinate(latitude: airportRow["lat"], longitude: airportRow["lon"]),
                elevationFeet: airportRow["elevation_ft"],
                magneticVariation: airportRow["mag_var"],
                runways: runways,
                frequencies: frequencies
            )

            return AirportDetail(
                airport: airport,
                plates: plates,
                trafficPatternAltitude: airportRow["tpa_ft"],
                siteType: airportRow["site_type"],
                facilityUse: airportRow["facility_use"]
            )
        }
    }
}
