import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import GRDB
import FBModels

/// Downloads the FAA NASR subscriber CSV bundles for a cycle and writes the
/// normalized aero database tables.
///
/// NASR CSV bundles live at
/// `https://nfdc.faa.gov/webContent/28DaySub/extra/{DD}_{Mon}_{YYYY}_{GROUP}_CSV.zip`
/// where the date is the cycle effective date. The FAA CDN rejects requests
/// without a browser-like User-Agent.
struct NASRIngestor {
    let workDirectory: URL
    let logger: (String) -> Void

    func run(cycle: DataCycle, into builder: AeroDatabaseBuilder) async throws {
        let groups = ["APT", "FRQ", "NAV", "FIX", "AWY"]
        var extracted: [String: URL] = [:]
        for group in groups {
            extracted[group] = try await fetchAndExtract(group: group, cycle: cycle)
        }

        try ingestAirports(directory: extracted["APT"]!, into: builder)
        try ingestFrequencies(directory: extracted["FRQ"]!, into: builder)
        try ingestNavaids(directory: extracted["NAV"]!, into: builder)
        try ingestFixes(directory: extracted["FIX"]!, into: builder)
        // Airways resolve their points against navaid/fix, so run last.
        try ingestAirways(directory: extracted["AWY"]!, into: builder)
    }

    // MARK: Download

    private func nasrDateComponent(for cycle: DataCycle) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "dd_MMM_yyyy"
        return formatter.string(from: cycle.effectiveDate)
    }

    private func fetchAndExtract(group: String, cycle: DataCycle) async throws -> URL {
        let fileName = "\(nasrDateComponent(for: cycle))_\(group)_CSV.zip"
        let zipURL = workDirectory.appendingPathComponent(fileName)
        let extractDir = workDirectory.appendingPathComponent("nasr_\(group)")

        if !FileManager.default.fileExists(atPath: zipURL.path) {
            let remote = URL(string: "https://nfdc.faa.gov/webContent/28DaySub/extra/\(fileName)")!
            logger("Downloading \(remote.lastPathComponent)…")
            let data = try await download(remote)
            try data.write(to: zipURL)
        } else {
            logger("Using cached \(fileName)")
        }

        try? FileManager.default.removeItem(at: extractDir)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        try unzip(zipURL, to: extractDir)
        return extractDir
    }

    private func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh) FlightBag-Ingest/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw IngestError("Download failed for \(url): HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        return data
    }

    private func unzip(_ zip: URL, to directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", "-q", zip.path, "-d", directory.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw IngestError("unzip failed for \(zip.lastPathComponent) (status \(process.terminationStatus))")
        }
    }

    private func csv(_ directory: URL, _ name: String) throws -> CSVTable {
        let url = directory.appendingPathComponent(name)
        return try CSVTable(data: try Data(contentsOf: url))
    }

    // MARK: Airports

    private func ingestAirports(directory: URL, into builder: AeroDatabaseBuilder) throws {
        let base = try csv(directory, "APT_BASE.csv")
        logger("APT_BASE: \(base.rows.count) rows")

        try builder.dbQueue.write { db in
            for row in base.rows {
                guard let id = base.value(row, "ARPT_ID"),
                      let name = base.value(row, "ARPT_NAME"),
                      let lat = base.double(row, "LAT_DECIMAL"),
                      let lon = base.double(row, "LONG_DECIMAL") else { continue }

                var magVar = base.double(row, "MAG_VARN")
                if let hemisphere = base.value(row, "MAG_HEMIS"), hemisphere == "W" {
                    magVar = magVar.map { -$0 }
                }

                try db.execute(
                    sql: """
                    INSERT OR REPLACE INTO airport
                    (id, icao_id, name, city, state, country, lat, lon, elevation_ft,
                     mag_var, tpa_ft, site_type, kind, facility_use, ownership, status)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        id,
                        base.value(row, "ICAO_ID"),
                        name,
                        base.value(row, "CITY"),
                        base.value(row, "STATE_CODE"),
                        base.value(row, "COUNTRY_CODE") ?? "US",
                        lat, lon,
                        base.double(row, "ELEV"),
                        magVar,
                        base.double(row, "TPA"),
                        base.value(row, "SITE_TYPE_CODE"),
                        AirportKind.fromNASR(siteTypeCode: base.value(row, "SITE_TYPE_CODE")).rawValue,
                        base.value(row, "FACILITY_USE_CODE"),
                        base.value(row, "OWNERSHIP_TYPE_CODE"),
                        base.value(row, "ARPT_STATUS"),
                    ]
                )
            }
        }

        let runways = try csv(directory, "APT_RWY.csv")
        logger("APT_RWY: \(runways.rows.count) rows")
        try builder.dbQueue.write { db in
            for row in runways.rows {
                guard let airportId = runways.value(row, "ARPT_ID"),
                      let designator = runways.value(row, "RWY_ID") else { continue }
                try db.execute(
                    sql: "INSERT INTO runway (airport_id, designator, length_ft, width_ft, surface) VALUES (?, ?, ?, ?, ?)",
                    arguments: [
                        airportId,
                        designator,
                        runways.int(row, "RWY_LEN"),
                        runways.int(row, "RWY_WIDTH"),
                        runways.value(row, "SURFACE_TYPE_CODE"),
                    ]
                )
            }
        }

        let ends = try csv(directory, "APT_RWY_END.csv")
        logger("APT_RWY_END: \(ends.rows.count) rows")
        try builder.dbQueue.write { db in
            for row in ends.rows {
                guard let airportId = ends.value(row, "ARPT_ID"),
                      let runwayDesignator = ends.value(row, "RWY_ID"),
                      let designator = ends.value(row, "RWY_END_ID") else { continue }
                try db.execute(
                    sql: """
                    INSERT INTO runway_end
                    (airport_id, runway_designator, designator, true_heading, lat, lon,
                     elevation_ft, displaced_threshold_ft, ils_type, right_pattern)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        airportId,
                        runwayDesignator,
                        designator,
                        ends.double(row, "TRUE_ALIGNMENT"),
                        ends.double(row, "LAT_DECIMAL"),
                        ends.double(row, "LONG_DECIMAL"),
                        ends.double(row, "RWY_END_ELEV"),
                        ends.int(row, "DISPLACED_THR_LEN"),
                        ends.value(row, "ILS_TYPE"),
                        ends.value(row, "RIGHT_HAND_TRAFFIC_PAT_FLAG") == "Y" ? 1 : 0,
                    ]
                )
            }
        }
    }

    // MARK: Frequencies

    private func ingestFrequencies(directory: URL, into builder: AeroDatabaseBuilder) throws {
        let table = try csv(directory, "FRQ.csv")
        logger("FRQ: \(table.rows.count) rows")

        // FRQ repeats a frequency once per STAR/DP sector; collapse to unique
        // (airport, freq, use) so airport pages aren't flooded.
        var seen = Set<String>()
        try builder.dbQueue.write { db in
            for row in table.rows {
                guard let airportId = table.value(row, "SERVICED_FACILITY"),
                      let freqString = table.value(row, "FREQ"),
                      let khz = megahertzStringToKHz(freqString) else { continue }
                let use = normalizedUse(table.value(row, "FREQ_USE"))
                let key = "\(airportId)|\(khz)|\(use ?? "")"
                guard seen.insert(key).inserted else { continue }

                try db.execute(
                    sql: """
                    INSERT INTO frequency (airport_id, facility, facility_type, freq_khz, use, call, sector)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        airportId,
                        table.value(row, "FACILITY"),
                        table.value(row, "FACILITY_TYPE"),
                        khz,
                        use,
                        table.value(row, "TOWER_OR_COMM_CALL"),
                        table.value(row, "SECTORIZATION"),
                    ]
                )
            }
        }
    }

    /// Collapse NASR FREQ_USE variants ("LCL/P", "SZAGI STAR", "APCH/P DEP/P")
    /// into stable display buckets, keeping the raw value when unrecognized.
    private func normalizedUse(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let upper = raw.uppercased()
        if upper.contains("ATIS") { return "ATIS" }
        if upper.contains("LCL") { return "TWR" }
        if upper.contains("GND") { return "GND" }
        if upper.contains("CD") && !upper.contains("CDR") { return "CD" }
        if upper.contains("CTAF") { return "CTAF" }
        if upper.contains("EMERG") { return "EMERG" }
        if upper.contains("APCH") && upper.contains("DEP") { return "APP/DEP" }
        if upper.contains("APCH") { return "APP" }
        if upper.contains("DEP") { return "DEP" }
        if upper.hasSuffix("STAR") || upper.hasSuffix("DP") { return "APP/DEP" }
        return raw
    }

    // MARK: Navaids & fixes

    private func ingestNavaids(directory: URL, into builder: AeroDatabaseBuilder) throws {
        let table = try csv(directory, "NAV_BASE.csv")
        logger("NAV_BASE: \(table.rows.count) rows")
        try builder.dbQueue.write { db in
            for row in table.rows {
                guard let id = table.value(row, "NAV_ID"),
                      let lat = table.double(row, "LAT_DECIMAL"),
                      let lon = table.double(row, "LONG_DECIMAL") else { continue }
                let freqKHz: Int?
                if let freq = table.value(row, "FREQ") {
                    // VOR frequencies are MHz ("117.10"); NDBs are kHz ("341").
                    freqKHz = freq.contains(".") ? megahertzStringToKHz(freq) : Int(freq)
                } else {
                    freqKHz = nil
                }
                try db.execute(
                    sql: "INSERT INTO navaid (id, type, name, lat, lon, freq_khz, channel) VALUES (?, ?, ?, ?, ?, ?, ?)",
                    arguments: [
                        id,
                        table.value(row, "NAV_TYPE"),
                        table.value(row, "NAME"),
                        lat, lon,
                        freqKHz,
                        table.value(row, "CHAN"),
                    ]
                )
            }
        }
    }

    // MARK: Airways

    /// AWY_BASE's AIRWAY_STRING is the ordered point list ("MAM GROSZ BRO …")
    /// mixing navaid and fix identifiers. Coordinates are baked in here so the
    /// app expands an airway with a single indexed query. Airway ids repeat
    /// across locations (Alaska/CONUS/Hawaii), so (id, location) is the key.
    private func ingestAirways(directory: URL, into builder: AeroDatabaseBuilder) throws {
        let table = try csv(directory, "AWY_BASE.csv")
        logger("AWY_BASE: \(table.rows.count) rows")

        // Identifier → candidate coordinates. Both maps preloaded once; fix
        // and navaid idents can be ambiguous (same ident, several sites).
        var fixCandidates: [String: [(Double, Double)]] = [:]
        var navaidCandidates: [String: [(Double, Double)]] = [:]
        try builder.dbQueue.read { db in
            for row in try Row.fetchAll(db, sql: "SELECT id, lat, lon FROM fix") {
                fixCandidates[row["id"], default: []].append((row["lat"], row["lon"]))
            }
            for row in try Row.fetchAll(db, sql: "SELECT id, lat, lon FROM navaid") {
                navaidCandidates[row["id"], default: []].append((row["lat"], row["lon"]))
            }
        }

        var resolvedCount = 0
        var unresolvedCount = 0

        try builder.dbQueue.write { db in
            for row in table.rows {
                guard let id = table.value(row, "AWY_ID"),
                      let location = table.value(row, "AWY_LOCATION"),
                      let airwayString = table.value(row, "AIRWAY_STRING") else { continue }
                let points = airwayString.split(separator: " ").map(String.init)
                guard !points.isEmpty else { continue }

                try db.execute(
                    sql: "INSERT OR REPLACE INTO airway (id, location, designation, point_count) VALUES (?, ?, ?, ?)",
                    arguments: [id, location, table.value(row, "AWY_DESIGNATION"), points.count]
                )

                var previous: (Double, Double)?
                for (seq, point) in points.enumerated() {
                    // 5-letter identifiers are fixes; 1–3 letter are navaids.
                    // Try the likely table first, fall back to the other.
                    let (primary, primaryType, fallback, fallbackType) = point.count >= 4
                        ? (fixCandidates[point], "fix", navaidCandidates[point], "navaid")
                        : (navaidCandidates[point], "navaid", fixCandidates[point], "fix")

                    var pointType: String?
                    var coordinate: (Double, Double)?
                    if let picked = pick(from: primary, location: location, near: previous) {
                        pointType = primaryType
                        coordinate = picked
                    } else if let picked = pick(from: fallback, location: location, near: previous) {
                        pointType = fallbackType
                        coordinate = picked
                    }

                    if coordinate != nil { resolvedCount += 1 } else { unresolvedCount += 1 }
                    if let coordinate { previous = coordinate }

                    try db.execute(
                        sql: "INSERT INTO airway_point (airway_id, location, seq, point_id, point_type, lat, lon) VALUES (?, ?, ?, ?, ?, ?, ?)",
                        arguments: [id, location, seq, point, pointType, coordinate?.0, coordinate?.1]
                    )
                }
            }
        }
        logger("Airway points: \(resolvedCount) resolved, \(unresolvedCount) unresolved")
    }

    /// Choose among ambiguous candidates: keep those in the airway's region
    /// (Alaska/Hawaii/CONUS), then take the one nearest the previous point.
    private func pick(from candidates: [(Double, Double)]?, location: String, near previous: (Double, Double)?) -> (Double, Double)? {
        guard let candidates, !candidates.isEmpty else { return nil }
        func inRegion(_ c: (Double, Double)) -> Bool {
            let isAlaska = c.0 > 48 && c.1 < -125
            let isHawaii = c.0 < 30 && c.1 < -150
            switch location {
            case "A": return isAlaska
            case "H": return isHawaii
            default: return !isAlaska && !isHawaii
            }
        }
        let regional = candidates.filter(inRegion)
        let pool = regional.isEmpty ? candidates : regional
        guard let previous else { return pool.first }
        return pool.min { a, b in
            let da = (a.0 - previous.0) * (a.0 - previous.0) + (a.1 - previous.1) * (a.1 - previous.1)
            let db = (b.0 - previous.0) * (b.0 - previous.0) + (b.1 - previous.1) * (b.1 - previous.1)
            return da < db
        }
    }

    private func ingestFixes(directory: URL, into builder: AeroDatabaseBuilder) throws {
        let table = try csv(directory, "FIX_BASE.csv")
        logger("FIX_BASE: \(table.rows.count) rows")
        try builder.dbQueue.write { db in
            for row in table.rows {
                guard let id = table.value(row, "FIX_ID"),
                      let lat = table.double(row, "LAT_DECIMAL"),
                      let lon = table.double(row, "LONG_DECIMAL") else { continue }
                try db.execute(
                    sql: "INSERT INTO fix (id, lat, lon, use_code, icao_region) VALUES (?, ?, ?, ?, ?)",
                    arguments: [
                        id, lat, lon,
                        table.value(row, "FIX_USE_CODE"),
                        table.value(row, "ICAO_REGION_CODE"),
                    ]
                )
            }
        }
    }
}
