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
        var cached = 0
        var failures: [(row: PlateRow, reason: String)] = []

        for (index, row) in rows.enumerated() {
            let target = stage.appendingPathComponent("\(row.airportId)/\(row.pdfName)")
            if Self.stagedPlateIsUsable(at: target) {
                cached += 1
            } else {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                do {
                    let data = try await fetchPlate(row)
                    // Stage to a sibling path and rename. A direct write that is
                    // interrupted — OOM kill, host suspend — leaves a truncated
                    // PDF that every later run would treat as cached and bundle.
                    let partial = target.appendingPathExtension("partial")
                    try? FileManager.default.removeItem(at: partial)
                    try data.write(to: partial)
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.moveItem(at: partial, to: target)
                    downloaded += 1
                } catch {
                    // Collect rather than abort: one run should report every bad
                    // plate, not force a re-download of the region per failure.
                    failures.append((row, "\(error)"))
                }
            }
            if (index + 1) % 25 == 0 || index + 1 == rows.count {
                logger("\(index + 1)/\(rows.count) plates staged")
            }
        }

        guard failures.isEmpty else {
            let shown = failures.prefix(20)
                .map { "  \($0.row.airportId)/\($0.row.pdfName): \($0.reason)" }
                .joined(separator: "\n")
            let more = failures.count > 20 ? "\n  …and \(failures.count - 20) more" : ""
            throw IngestError("""
                \(failures.count) of \(rows.count) plates failed for \(regionId); bundle not written:
                \(shown)\(more)
                """)
        }
        // Completeness is checkable, so check it: the bundle must account for
        // every row the database claims for this region.
        guard downloaded + cached == rows.count else {
            throw IngestError("Plate accounting mismatch for \(regionId): \(downloaded) fetched + \(cached) cached != \(rows.count) expected")
        }
        logger("\(downloaded) fetched, \(cached) cached")

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

    private static let maxAttempts = 3

    /// A staged file counts as cached only if it still looks like a PDF, so a
    /// truncated leftover from an interrupted run is re-fetched rather than
    /// silently shipped.
    private static func stagedPlateIsUsable(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return looksLikePDF((try? handle.read(upToCount: 1024)) ?? Data())
    }

    /// aeronav occasionally answers 200 with an HTML error page; without this
    /// the page gets zipped into the bundle as though it were a chart.
    private static func looksLikePDF(_ head: Data) -> Bool {
        head.range(of: Data("%PDF-".utf8)) != nil
    }

    /// Fetches one plate, retrying only what retrying can fix.
    private func fetchPlate(_ row: PlateRow) async throws -> Data {
        var lastReason = "no attempt made"
        for attempt in 1...Self.maxAttempts {
            var request = URLRequest(url: row.url)
            request.setValue("Mozilla/5.0 (Macintosh) FlightBag-Ingest/1.0", forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                if status == 200 {
                    guard Self.looksLikePDF(data.prefix(1024)) else {
                        throw IngestError("HTTP 200 but body is not a PDF (\(data.count) bytes)")
                    }
                    return data
                }
                // 4xx other than rate limiting is the FAA stating this URL is
                // wrong. Retrying cannot change that, and 404 in particular
                // means the metafile and the file server disagree.
                if (400..<500).contains(status), status != 429 {
                    throw IngestError("HTTP \(status)")
                }
                lastReason = "HTTP \(status)"
            } catch let error as IngestError {
                throw error
            } catch {
                // Timeouts, resets, DNS blips — the cases worth another go.
                lastReason = "\(error)"
            }
            if attempt < Self.maxAttempts {
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
            }
        }
        throw IngestError("\(lastReason) after \(Self.maxAttempts) attempts")
    }
}
