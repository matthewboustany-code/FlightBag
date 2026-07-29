import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import GRDB
import FBModels

/// Worldwide airport, runway, frequency and navaid data from OurAirports.
///
/// OurAirports releases everything to the **public domain** and rebuilds the
/// CSVs daily, so unlike NASR there is no cycle in the URL — an ingest run
/// takes whatever is current and stamps it with the cycle being built.
///
/// The columns line up with the existing schema almost exactly: elevations and
/// runway dimensions are already in feet, headings already true, frequencies
/// already keyed by airport ident. `iso_region` even arrives in the same
/// "US-TX"/"GB-ENG" shape `Region.id` uses.
///
/// This does **not** replace NASR anywhere NASR runs. See `coveredCountries`.
struct OurAirportsIngestor {
    let workDirectory: URL
    let logger: (String) -> Void

    /// Stable mirror of the daily OurAirports exports.
    static let baseURL = URL(string: "https://davidmegginson.github.io/ourairports-data")!

    /// Airport types OurAirports publishes that we do not want as searchable
    /// aerodromes. Closed fields especially: showing one as usable is worse
    /// than not showing it.
    static let excludedTypes: Set<String> = ["closed"]

    func run(into builder: AeroDatabaseBuilder) async throws {
        // Countries an earlier, more authoritative ingest already covered.
        // In a normal `ingest-all` that means NASR has filled in the US, so
        // OurAirports must not duplicate it — NASR publishes KAUS as local
        // ident "AUS" with icao_id "KAUS" while OurAirports publishes ident
        // "KAUS", so the two would not collide on the primary key and we would
        // silently end up with the airport twice.
        //
        // Deriving this from the database rather than a flag means an
        // OurAirports-only run (no NASR) still produces US airports.
        let covered = try coveredCountries(in: builder)
        if !covered.isEmpty {
            logger("OurAirports: deferring to existing data for \(covered.sorted().joined(separator: ", "))")
        }

        let airports = try await table("airports.csv")
        let keptIdents = try ingestAirports(airports, excluding: covered, into: builder)
        logger("OurAirports: \(keptIdents.count) airports")

        try await ingestRunways(table("runways.csv"), keeping: keptIdents, into: builder)
        try await ingestFrequencies(table("airport-frequencies.csv"), keeping: keptIdents, into: builder)
        try await ingestNavaids(table("navaids.csv"), excluding: covered, into: builder)
    }

    /// Countries already populated by some other authority.
    func coveredCountries(in builder: AeroDatabaseBuilder) throws -> Set<String> {
        try builder.dbQueue.read { db in
            Set(try String.fetchAll(
                db,
                sql: "SELECT DISTINCT country FROM airport WHERE authority <> ?",
                arguments: [DataAuthority.ourAirports.rawValue]
            ))
        }
    }

    // MARK: Download

    private func table(_ name: String) async throws -> CSVTable {
        let cached = workDirectory.appendingPathComponent("ourairports_\(name)")
        let data: Data
        if FileManager.default.fileExists(atPath: cached.path) {
            logger("Using cached \(name)")
            data = try Data(contentsOf: cached)
        } else {
            let remote = Self.baseURL.appendingPathComponent(name)
            logger("Downloading \(name)…")
            data = try await download(remote)
            try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
            try data.write(to: cached)
        }
        return try CSVTable(data: data)
    }

    private func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("FlightBag-Ingest/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw IngestError("Download failed for \(url): HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        return data
    }

    // MARK: Airports

    /// Returns the set of OurAirports idents actually written, so the child
    /// tables can skip rows belonging to airports we excluded.
    @discardableResult
    func ingestAirports(
        _ table: CSVTable,
        excluding covered: Set<String>,
        into builder: AeroDatabaseBuilder
    ) throws -> Set<String> {
        var kept: Set<String> = []
        try builder.dbQueue.write { db in
            for row in table.rows {
                guard let ident = table.value(row, "ident"),
                      let name = table.value(row, "name"),
                      let lat = table.double(row, "latitude_deg"),
                      let lon = table.double(row, "longitude_deg") else { continue }

                let country = table.value(row, "iso_country") ?? ""
                guard !covered.contains(country) else { continue }

                let type = table.value(row, "type") ?? ""
                guard !Self.excludedTypes.contains(type) else { continue }

                try db.execute(
                    sql: """
                    INSERT OR REPLACE INTO airport
                    (id, icao_id, name, city, state, country, iso_region, lat, lon,
                     elevation_ft, mag_var, tpa_ft, site_type, kind, facility_use, ownership,
                     status, authority)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        ident,
                        table.value(row, "icao_code"),
                        name,
                        table.value(row, "municipality"),
                        // `iso_region` is "GB-ENG"; the bare subdivision is
                        // what the existing `state` column holds.
                        table.value(row, "iso_region").map { String($0.split(separator: "-").last ?? "") },
                        country,
                        table.value(row, "iso_region"),
                        lat, lon,
                        table.double(row, "elevation_ft"),
                        // OurAirports publishes no magnetic variation or
                        // pattern altitude. Leaving them null is correct —
                        // a computed guess would look authoritative.
                        nil, nil,
                        type,
                        AirportKind.fromOurAirports(type: type).rawValue,
                        nil, nil,
                        nil,
                        DataAuthority.ourAirports.rawValue,
                    ]
                )
                kept.insert(ident)
            }
        }
        return kept
    }

    // MARK: Runways

    func ingestRunways(
        _ table: CSVTable,
        keeping idents: Set<String>,
        into builder: AeroDatabaseBuilder
    ) throws {
        try builder.dbQueue.write { db in
            for row in table.rows {
                guard let airportId = table.value(row, "airport_ident"), idents.contains(airportId) else { continue }
                // "1" means closed; a closed runway is not a usable one.
                if table.value(row, "closed") == "1" { continue }

                let le = table.value(row, "le_ident")
                let he = table.value(row, "he_ident")
                let designator = [le, he].compactMap(\.self).joined(separator: "/")
                guard !designator.isEmpty else { continue }

                try db.execute(
                    sql: "INSERT INTO runway (airport_id, designator, length_ft, width_ft, surface) VALUES (?, ?, ?, ?, ?)",
                    arguments: [
                        airportId,
                        designator,
                        table.int(row, "length_ft"),
                        table.int(row, "width_ft"),
                        table.value(row, "surface"),
                    ]
                )

                for (endIdent, prefix) in [(le, "le"), (he, "he")] {
                    guard let endIdent else { continue }
                    try db.execute(
                        sql: """
                        INSERT INTO runway_end
                        (airport_id, runway_designator, designator, true_heading, lat, lon,
                         elevation_ft, displaced_threshold_ft, ils_type, right_pattern)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
                        """,
                        arguments: [
                            airportId,
                            designator,
                            endIdent,
                            table.double(row, "\(prefix)_heading_degT"),
                            table.double(row, "\(prefix)_latitude_deg"),
                            table.double(row, "\(prefix)_longitude_deg"),
                            table.double(row, "\(prefix)_elevation_ft"),
                            table.int(row, "\(prefix)_displaced_threshold_ft"),
                            nil,
                        ]
                    )
                }
            }
        }
    }

    // MARK: Frequencies

    func ingestFrequencies(
        _ table: CSVTable,
        keeping idents: Set<String>,
        into builder: AeroDatabaseBuilder
    ) throws {
        try builder.dbQueue.write { db in
            for row in table.rows {
                guard let airportId = table.value(row, "airport_ident"), idents.contains(airportId),
                      let mhz = table.value(row, "frequency_mhz"),
                      let kHz = megahertzStringToKHz(mhz) else { continue }
                try db.execute(
                    sql: "INSERT INTO frequency (airport_id, facility, facility_type, freq_khz, use, call, sector) VALUES (?, ?, ?, ?, ?, ?, ?)",
                    arguments: [
                        airportId,
                        table.value(row, "description"),
                        table.value(row, "type"),
                        kHz,
                        table.value(row, "type"),
                        nil, nil,
                    ]
                )
            }
        }
    }

    // MARK: Navaids

    /// OurAirports navaid types → the schema's `type` vocabulary, which
    /// mirrors `Navaid.Kind`.
    static let navaidTypes: [String: String] = [
        "VOR": "vor",
        "VOR-DME": "vorDme",
        "VORTAC": "vortac",
        "DME": "dme",
        "NDB": "ndb",
        "NDB-DME": "ndb",
        "TACAN": "tacan",
    ]

    func ingestNavaids(
        _ table: CSVTable,
        excluding covered: Set<String>,
        into builder: AeroDatabaseBuilder
    ) throws {
        try builder.dbQueue.write { db in
            for row in table.rows {
                guard let ident = table.value(row, "ident"),
                      let lat = table.double(row, "latitude_deg"),
                      let lon = table.double(row, "longitude_deg") else { continue }
                guard !covered.contains(table.value(row, "iso_country") ?? "") else { continue }

                let rawType = table.value(row, "type") ?? ""
                guard let kind = Self.navaidTypes[rawType] else { continue }

                try db.execute(
                    sql: "INSERT INTO navaid (id, type, name, lat, lon, freq_khz, channel, authority) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                    arguments: [
                        ident,
                        kind,
                        table.value(row, "name"),
                        lat, lon,
                        table.int(row, "frequency_khz"),
                        table.value(row, "dme_channel"),
                        DataAuthority.ourAirports.rawValue,
                    ]
                )
            }
        }
    }
}
