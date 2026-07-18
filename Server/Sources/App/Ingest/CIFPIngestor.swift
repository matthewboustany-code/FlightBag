import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import GRDB
import FBModels

/// Downloads the FAA CIFP (ARINC 424 coded procedures) for a cycle and
/// writes SID/STAR geometry into `procedure`/`procedure_leg` — enough to
/// draw a procedure's branches on the map and label its fixes, not to fly
/// it. Two passes over FAACIFP18: fix index (waypoints/navaids/runways),
/// then PD/PE legs with coordinates resolved at ingest so the app never
/// joins.
struct CIFPIngestor {
    let workDirectory: URL
    let logger: (String) -> Void

    /// `input` overrides the download — escape hatch for URL drift.
    func run(cycle: DataCycle, into builder: AeroDatabaseBuilder, input: String? = nil) async throws {
        let file: URL
        if let input {
            file = URL(fileURLWithPath: input)
        } else {
            file = try await download(cycle: cycle)
        }

        logger("CIFP: indexing fixes…")
        var fixes: [ARINC424.FixKey: (Double, Double)] = [:]
        try forEachLine(of: file) { line in
            if case .fix(let fix) = ARINC424.parse(line) {
                fixes[fix.key] = (fix.latitude, fix.longitude)
            }
        }
        logger("CIFP: \(fixes.count) fixes indexed")

        var legs: [ARINC424.ProcedureLeg] = []
        try forEachLine(of: file) { line in
            if case .leg(let leg) = ARINC424.parse(line) {
                legs.append(leg)
            }
        }

        // Group into procedures, resolve each leg's fix.
        struct ProcedureKey: Hashable {
            let airportId: String
            let ident: String
            let isSID: Bool
        }
        let grouped = Dictionary(grouping: legs) {
            ProcedureKey(airportId: $0.airportId, ident: $0.procedureIdent, isSID: $0.isSID)
        }

        // Resolve everything up front so the write closure only touches
        // immutable prepared values (Swift 6 sendability).
        struct PreparedLeg: Sendable {
            let transitionKind: String
            let transitionIdent: String?
            let sequence: Int
            let fixIdent: String
            let latitude: Double
            let longitude: Double
            let pathTerminator: String
            let altitudeDescription: String?
            let altitude1Feet: Int?
            let speedLimitKt: Int?
        }
        struct PreparedProcedure: Sendable {
            let airportId: String
            let ident: String
            let kind: String
            let legs: [PreparedLeg]
        }

        var unresolved = 0
        let prepared: [PreparedProcedure] = grouped
            .sorted { ($0.key.airportId, $0.key.ident) < ($1.key.airportId, $1.key.ident) }
            .map { key, procedureLegs in
                let legs = procedureLegs
                    .sorted { ($0.transitionIdent ?? "", $0.sequence) < ($1.transitionIdent ?? "", $1.sequence) }
                    .compactMap { leg -> PreparedLeg? in
                        guard let coordinate = resolve(leg: leg, fixes: fixes) else {
                            unresolved += 1
                            return nil
                        }
                        return PreparedLeg(
                            transitionKind: leg.transitionKind.rawValue,
                            transitionIdent: leg.transitionIdent,
                            sequence: leg.sequence,
                            fixIdent: leg.fixIdent,
                            latitude: coordinate.0,
                            longitude: coordinate.1,
                            pathTerminator: leg.pathTerminator,
                            altitudeDescription: leg.altitudeDescription,
                            altitude1Feet: leg.altitude1Feet,
                            speedLimitKt: leg.speedLimitKt
                        )
                    }
                return PreparedProcedure(airportId: key.airportId, ident: key.ident, kind: key.isSID ? "sid" : "star", legs: legs)
            }
        let written = prepared.map(\.legs.count).reduce(0, +)

        try await builder.dbQueue.write { db in
            // Rerun-safe (mirrors the plate delete); also create the tables
            // when appending to a pre-v3 database.
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS procedure (
                    id INTEGER PRIMARY KEY, airport_id TEXT NOT NULL, ident TEXT NOT NULL, kind TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_procedure_airport ON procedure(airport_id);
                CREATE TABLE IF NOT EXISTS procedure_leg (
                    procedure_id INTEGER NOT NULL, transition_kind TEXT NOT NULL, transition_ident TEXT,
                    seq INTEGER NOT NULL, fix_ident TEXT NOT NULL, lat REAL NOT NULL, lon REAL NOT NULL,
                    path_term TEXT, alt_desc TEXT, alt1_ft INTEGER, speed_kt INTEGER
                );
                CREATE INDEX IF NOT EXISTS idx_procedure_leg ON procedure_leg(procedure_id, transition_kind, transition_ident, seq);
                DELETE FROM procedure_leg;
                DELETE FROM procedure;
                """)
            // Appending procedures upgrades a pre-v3 database — stamp it so
            // the app-side schema gate shows them.
            let stamped = (try? String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'schema_version'")).flatMap { $0.flatMap(Int.init) } ?? 1
            if stamped < 3 {
                try db.execute(sql: "INSERT OR REPLACE INTO meta VALUES ('schema_version', '3')")
            }

            for procedure in prepared {
                try db.execute(
                    sql: "INSERT INTO procedure (airport_id, ident, kind) VALUES (?, ?, ?)",
                    arguments: [procedure.airportId, procedure.ident, procedure.kind]
                )
                let procedureId = db.lastInsertedRowID
                for leg in procedure.legs {
                    try db.execute(
                        sql: """
                        INSERT INTO procedure_leg
                            (procedure_id, transition_kind, transition_ident, seq, fix_ident, lat, lon, path_term, alt_desc, alt1_ft, speed_kt)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            procedureId, leg.transitionKind, leg.transitionIdent, leg.sequence,
                            leg.fixIdent, leg.latitude, leg.longitude, leg.pathTerminator,
                            leg.altitudeDescription, leg.altitude1Feet, leg.speedLimitKt,
                        ]
                    )
                }
            }
        }
        logger("CIFP: \(grouped.count) procedures, \(written) legs (\(unresolved) legs skipped: unresolvable fix)")
    }

    /// Terminal fixes resolve within the procedure's airport first, then
    /// globally (some procedures reference another airport's terminal fix).
    private func resolve(leg: ARINC424.ProcedureLeg, fixes: [ARINC424.FixKey: (Double, Double)]) -> (Double, Double)? {
        switch leg.fixSection {
        case "PC", "PG":
            return fixes[ARINC424.FixKey(section: leg.fixSection, airportId: leg.airportId, ident: leg.fixIdent)]
        case "EA", "D", "DB":
            return fixes[ARINC424.FixKey(section: leg.fixSection, airportId: nil, ident: leg.fixIdent)]
        default:
            // Unknown reference section: try terminal-then-global.
            return fixes[ARINC424.FixKey(section: "PC", airportId: leg.airportId, ident: leg.fixIdent)]
                ?? fixes[ARINC424.FixKey(section: "EA", airportId: nil, ident: leg.fixIdent)]
                ?? fixes[ARINC424.FixKey(section: "D", airportId: nil, ident: leg.fixIdent)]
                ?? fixes[ARINC424.FixKey(section: "DB", airportId: nil, ident: leg.fixIdent)]
        }
    }

    // MARK: Download + reading

    private func download(cycle: DataCycle) async throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyMMdd"
        let stamp = formatter.string(from: cycle.effectiveDate)

        let zipURL = workDirectory.appendingPathComponent("cifp_\(cycle.id).zip")
        if !FileManager.default.fileExists(atPath: zipURL.path) {
            let remote = URL(string: "https://aeronav.faa.gov/Upload_313-d/cifp/CIFP_\(stamp).zip")!
            logger("Downloading \(remote.absoluteString)…")
            var request = URLRequest(url: remote)
            request.setValue("Mozilla/5.0 (Macintosh) FlightBag-Ingest/1.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw IngestError("CIFP download failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1). If the FAA moved the file, re-run with --input pointing at a manually downloaded FAACIFP18.")
            }
            try data.write(to: zipURL)
        } else {
            logger("Using cached \(zipURL.lastPathComponent)")
        }

        let extractDir = workDirectory.appendingPathComponent("cifp_\(cycle.id)", isDirectory: true)
        try? FileManager.default.removeItem(at: extractDir)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        try runIngestProcess("/usr/bin/unzip", ["-o", "-q", zipURL.path, "-d", extractDir.path])
        let file = extractDir.appendingPathComponent("FAACIFP18")
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw IngestError("FAACIFP18 not found in the CIFP zip")
        }
        return file
    }

    private func forEachLine(of file: URL, _ body: (String) -> Void) throws {
        // ~400k ASCII lines; whole-file read is ~50 MB and simplest.
        let data = try String(contentsOf: file, encoding: .utf8)
        for line in data.split(whereSeparator: \.isNewline) {
            body(String(line))
        }
    }
}
