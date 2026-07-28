import Foundation
import GRDB
import FBModels
import FBFlightPlan

/// Read-only access to the per-cycle aviation database (`aero.sqlite`) built
/// by the server ingestion pipeline. A bundled seed copy ships with the app;
/// downloaded cycle updates land in the same directory layout and win by
/// being newer.
final class AeroDatabase: Sendable {
    private let dbQueue: DatabaseQueue
    let cycle: DataCycle?
    /// Schema generation of this database; pre-airway builds report 1.
    let schemaVersion: Int

    /// Opens the newest available database, installing the bundled seed into
    /// Application Support on first launch. An installed database of the same
    /// cycle loses to a seed with a newer schema (app updates can add tables
    /// mid-cycle, e.g. airways in Phase 3).
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

        let seed = Bundle.main.url(forResource: "aero", withExtension: "sqlite")
        let seedDB = try seed.map { try AeroDatabase(path: $0.path) }

        if let newest = installed.last {
            let installedDB = try AeroDatabase(path: cyclesRoot.appendingPathComponent("\(newest)/aero.sqlite").path)
            let seedIsBetter = seedDB.map {
                ($0.cycle?.id ?? "") > newest
                    || (($0.cycle?.id ?? "") == newest && $0.schemaVersion > installedDB.schemaVersion)
            } ?? false
            if !seedIsBetter {
                return installedDB
            }
        }

        guard let seed, let seedDB else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Bundled aero.sqlite missing"])
        }
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
        (cycle, schemaVersion) = try dbQueue.read { db in
            let cycle = (try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'cycle'"))
                .flatMap(DataCycle.init(id:))
            let schema = (try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'schema_version'"))
                .flatMap(Int.init) ?? 1
            return (cycle, schema)
        }
    }

    // MARK: Search

    struct SearchResult: Identifiable, Sendable, Hashable {
        let id: String
        let icaoId: String?
        let name: String
        let city: String?
        let state: String?
        var latitude: Double?
        var longitude: Double?

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
                SELECT a.id, a.icao_id, a.name, a.city, a.state, a.lat, a.lon
                FROM airport_rtree r
                JOIN airport a ON a.rowid = r.id
                WHERE r.min_lat >= ? AND r.max_lat <= ? AND r.min_lon >= ? AND r.max_lon <= ?
                  AND a.site_type = 'A'
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
                SearchResult(
                    id: row["id"], icaoId: row["icao_id"], name: row["name"],
                    city: row["city"], state: row["state"],
                    latitude: row["lat"], longitude: row["lon"]
                )
            }
        }
    }

    /// Airport for the map's aeronautical layer, with an importance tier so
    /// zoomed-out views can show only the airports a pilot would look for.
    struct MapAirport: Sendable, Hashable {
        let id: String
        let icaoId: String?
        let name: String
        let latitude: Double
        let longitude: Double
        /// 0 = towered with a ≥6000′ runway, 1 = towered or ≥5000′, 2 = rest.
        let tier: Int

        var displayIdentifier: String { icaoId ?? id }
    }

    func mapAirportsNear(
        latitude: Double,
        longitude: Double,
        spanDegrees: Double,
        maxTier: Int,
        limit: Int
    ) async throws -> [MapAirport] {
        try await dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT id, icao_id, name, lat, lon,
                    CASE
                        WHEN twr AND longest >= 6000 THEN 0
                        WHEN twr OR longest >= 5000 THEN 1
                        ELSE 2
                    END AS tier
                FROM (
                    SELECT a.id, a.icao_id, a.name, a.lat, a.lon,
                        EXISTS(SELECT 1 FROM frequency f WHERE f.airport_id = a.id AND f.use = 'TWR') AS twr,
                        COALESCE((SELECT MAX(length_ft) FROM runway rw WHERE rw.airport_id = a.id), 0) AS longest
                    FROM airport_rtree r
                    JOIN airport a ON a.rowid = r.id
                    WHERE r.min_lat >= ? AND r.max_lat <= ? AND r.min_lon >= ? AND r.max_lon <= ?
                      AND a.site_type = 'A'
                )
                WHERE tier <= ?
                ORDER BY tier, (lat - ?) * (lat - ?) + (lon - ?) * (lon - ?)
                LIMIT ?
                """,
                arguments: [
                    latitude - spanDegrees, latitude + spanDegrees,
                    longitude - spanDegrees, longitude + spanDegrees,
                    maxTier,
                    latitude, latitude, longitude, longitude,
                    limit,
                ]
            ).map { row in
                MapAirport(
                    id: row["id"], icaoId: row["icao_id"], name: row["name"],
                    latitude: row["lat"], longitude: row["lon"], tier: row["tier"]
                )
            }
        }
    }

    // MARK: Procedures (SID/STAR, schema v3+)

    struct ProcedureSummary: Sendable, Hashable {
        let ident: String
        /// "sid" | "star"
        let kind: String
    }

    struct ProcedureLegRow: Sendable, Hashable {
        let transitionKind: String
        let transitionIdent: String?
        let seq: Int
        let fixIdent: String
        let latitude: Double
        let longitude: Double
    }

    /// CIFP keys procedures by the 4-char ICAO-style ident ("KAUS"), so
    /// query by both the FAA id and the ICAO id.
    func procedures(airportId: String, icaoId: String?) async throws -> [ProcedureSummary] {
        guard schemaVersion >= 3 else { return [] }
        return try await dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT DISTINCT ident, kind FROM procedure WHERE airport_id IN (?, ?) ORDER BY kind, ident",
                arguments: [airportId, icaoId ?? airportId]
            ).map { ProcedureSummary(ident: $0["ident"], kind: $0["kind"]) }
        }
    }

    func procedureLegs(airportId: String, icaoId: String?, ident: String) async throws -> [ProcedureLegRow] {
        guard schemaVersion >= 3 else { return [] }
        return try await dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT l.transition_kind, l.transition_ident, l.seq, l.fix_ident, l.lat, l.lon
                FROM procedure p
                JOIN procedure_leg l ON l.procedure_id = p.id
                WHERE p.airport_id IN (?, ?) AND p.ident = ?
                ORDER BY l.transition_kind, l.transition_ident, l.seq
                """,
                arguments: [airportId, icaoId ?? airportId, ident]
            ).map {
                ProcedureLegRow(
                    transitionKind: $0["transition_kind"],
                    transitionIdent: $0["transition_ident"],
                    seq: $0["seq"],
                    fixIdent: $0["fix_ident"],
                    latitude: $0["lat"],
                    longitude: $0["lon"]
                )
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

// MARK: Aeronautical map layer queries

extension AeroDatabase {
    struct MapWaypoint: Sendable, Hashable, Identifiable {
        enum Kind: Sendable, Hashable {
            case navaid(type: String?)
            case fix
        }

        var id: String { "\(identifier)-\(latitude)-\(longitude)" }
        var identifier: String
        var name: String?
        var kind: Kind
        var latitude: Double
        var longitude: Double
    }

    struct AirwayLine: Sendable, Hashable, Identifiable {
        var id: String { ident }
        var ident: String
        /// Jet/Q routes (18,000 ft and up) vs victor/T low structure.
        var isHigh: Bool
        var coordinates: [Coordinate]
    }

    func navaidsIn(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double, limit: Int = 80) async throws -> [MapWaypoint] {
        try await dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT id, type, name, lat, lon FROM navaid
                WHERE lat BETWEEN ? AND ? AND lon BETWEEN ? AND ?
                LIMIT ?
                """,
                arguments: [minLat, maxLat, minLon, maxLon, limit]
            ).map { row in
                MapWaypoint(identifier: row["id"], name: row["name"], kind: .navaid(type: row["type"]), latitude: row["lat"], longitude: row["lon"])
            }
        }
    }

    func fixesIn(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double, limit: Int = 150) async throws -> [MapWaypoint] {
        try await dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT id, lat, lon FROM fix
                WHERE lat BETWEEN ? AND ? AND lon BETWEEN ? AND ?
                LIMIT ?
                """,
                arguments: [minLat, maxLat, minLon, maxLon, limit]
            ).map { row in
                MapWaypoint(identifier: row["id"], name: nil, kind: .fix, latitude: row["lat"], longitude: row["lon"])
            }
        }
    }

    /// Airways with at least one point in the box, each returned complete so
    /// the polyline doesn't stop at the screen edge.
    func airwaysIn(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double, limit: Int = 60) async throws -> [AirwayLine] {
        guard schemaVersion >= 2 else { return [] }
        return try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT p.airway_id, a.designation, p.seq, p.lat, p.lon
                FROM airway_point p
                JOIN airway a ON a.id = p.airway_id AND a.location = p.location
                WHERE p.location = 'C' AND p.lat IS NOT NULL AND p.airway_id IN (
                    SELECT DISTINCT airway_id FROM airway_point
                    WHERE location = 'C' AND lat BETWEEN ? AND ? AND lon BETWEEN ? AND ?
                    LIMIT ?
                )
                ORDER BY p.airway_id, p.seq
                """,
                arguments: [minLat, maxLat, minLon, maxLon, limit]
            )
            var lines: [String: (designation: String?, points: [Coordinate])] = [:]
            var order: [String] = []
            for row in rows {
                let ident: String = row["airway_id"]
                if lines[ident] == nil {
                    lines[ident] = (row["designation"], [])
                    order.append(ident)
                }
                lines[ident]?.points.append(Coordinate(latitude: row["lat"], longitude: row["lon"]))
            }
            return order.compactMap { ident in
                guard let line = lines[ident], line.points.count >= 2 else { return nil }
                let designation = (line.designation ?? "").uppercased()
                return AirwayLine(
                    ident: ident,
                    isHigh: designation == "J" || designation == "Q",
                    coordinates: line.points
                )
            }
        }
    }
}

// MARK: Route waypoint resolution

extension AeroDatabase: WaypointResolving {
    /// Resolve a route token the way pilots write them: 5-letter tokens are
    /// fixes, 4-letter are airports, 1–3 letter are navaids — with fallbacks
    /// so "SAT" (airport and VORTAC) still resolves either way. Ambiguous
    /// identifiers prefer CONUS sites; airway context refines the rest.
    func resolveWaypoint(identifier: String, near anchor: Coordinate?) async throws -> ResolvedWaypoint? {
        let ident = identifier.uppercased()
        let attempts: [() async throws -> ResolvedWaypoint?]
        switch ident.count {
        case 5:
            attempts = [{ try await self.fix(ident) }, { try await self.airportWaypoint(ident) }]
        case 4:
            attempts = [{ try await self.airportWaypoint(ident) }, { try await self.fix(ident) }, { try await self.navaid(ident, near: anchor) }]
        default:
            attempts = [{ try await self.navaid(ident, near: anchor) }, { try await self.airportWaypoint(ident) }, { try await self.fix(ident) }]
        }
        for attempt in attempts {
            if let waypoint = try await attempt() { return waypoint }
        }
        return nil
    }

    func isAirway(identifier: String) async throws -> Bool {
        guard schemaVersion >= 2 else { return false }
        return try await dbQueue.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM airway WHERE id = ?)", arguments: [identifier.uppercased()]) ?? false
        }
    }

    func airwayPoints(identifier: String) async throws -> [ResolvedWaypoint] {
        guard schemaVersion >= 2 else { return [] }
        return try await dbQueue.read { db in
            // Airway ids repeat across Alaska/CONUS/Hawaii; prefer CONUS ('C')
            // until international/regional context exists.
            guard let location = try String.fetchOne(
                db,
                sql: "SELECT location FROM airway WHERE id = ? ORDER BY CASE location WHEN 'C' THEN 0 ELSE 1 END LIMIT 1",
                arguments: [identifier.uppercased()]
            ) else { return [] }

            return try Row.fetchAll(
                db,
                sql: "SELECT point_id, point_type, lat, lon FROM airway_point WHERE airway_id = ? AND location = ? ORDER BY seq",
                arguments: [identifier.uppercased(), location]
            ).compactMap { row in
                guard let lat = row["lat"] as Double?, let lon = row["lon"] as Double? else { return nil }
                return ResolvedWaypoint(
                    identifier: row["point_id"],
                    coordinate: Coordinate(latitude: lat, longitude: lon),
                    kind: (row["point_type"] as String?) == "navaid" ? .navaid : .fix
                )
            }
        }
    }

    private func airportWaypoint(_ ident: String) async throws -> ResolvedWaypoint? {
        try await dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT id, icao_id, name, lat, lon FROM airport WHERE icao_id = ? OR id = ? LIMIT 1", arguments: [ident, ident])
                .map { row in
                    ResolvedWaypoint(
                        identifier: (row["icao_id"] as String?) ?? row["id"],
                        name: row["name"],
                        coordinate: Coordinate(latitude: row["lat"], longitude: row["lon"]),
                        kind: .airport
                    )
                }
        }
    }

    /// Navaid identifiers are unique only within a region. Worldwide, about a
    /// third of them collide — "LON" is London *and* Londrina, "FFM" is
    /// Frankfurt *and* Fergus Falls — so with an anchor we take the nearest
    /// candidate, and without one we fall back to the CONUS preference that
    /// served the US-only database.
    private func navaid(_ ident: String, near anchor: Coordinate? = nil) async throws -> ResolvedWaypoint? {
        try await dbQueue.read { db in
            let sql: String
            var arguments: StatementArguments = [ident]
            if let anchor {
                // Ordering by squared degrees is enough to pick a winner and
                // avoids trigonometry in SQLite; longitude is cosine-scaled so
                // the comparison stays sane away from the equator.
                sql = """
                SELECT id, name, lat, lon FROM navaid WHERE id = ?
                ORDER BY (lat - ?) * (lat - ?)
                       + ((lon - ?) * (lon - ?)) * ?
                LIMIT 1
                """
                let cosLat = cos(anchor.latitude * .pi / 180)
                arguments += [
                    anchor.latitude, anchor.latitude,
                    anchor.longitude, anchor.longitude,
                    cosLat * cosLat,
                ]
            } else {
                sql = """
                SELECT id, name, lat, lon FROM navaid WHERE id = ?
                ORDER BY CASE WHEN (lat > 48 AND lon < -125) OR (lat < 30 AND lon < -150) THEN 1 ELSE 0 END
                LIMIT 1
                """
            }
            return try Row.fetchOne(db, sql: sql, arguments: arguments).map { row in
                ResolvedWaypoint(
                    identifier: row["id"],
                    name: row["name"],
                    coordinate: Coordinate(latitude: row["lat"], longitude: row["lon"]),
                    kind: .navaid
                )
            }
        }
    }

    private func fix(_ ident: String) async throws -> ResolvedWaypoint? {
        try await dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                SELECT id, lat, lon FROM fix WHERE id = ?
                ORDER BY CASE WHEN icao_region = 'K' THEN 0 ELSE 1 END
                LIMIT 1
                """,
                arguments: [ident]
            ).map { row in
                ResolvedWaypoint(
                    identifier: row["id"],
                    coordinate: Coordinate(latitude: row["lat"], longitude: row["lon"]),
                    kind: .fix
                )
            }
        }
    }
}
