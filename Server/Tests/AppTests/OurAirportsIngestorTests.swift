import Foundation
import Testing
import GRDB
import FBModels
@testable import App

@Suite struct OurAirportsIngestorTests {
    // Trimmed to the columns the ingestor reads, in the real file's order.
    private static let airportsCSV = """
    id,ident,type,name,latitude_deg,longitude_deg,elevation_ft,continent,iso_country,iso_region,municipality,scheduled_service,icao_code,iata_code,gps_code,local_code
    1,EGLL,large_airport,London Heathrow Airport,51.4706,-0.461941,83,EU,GB,GB-ENG,London,yes,EGLL,LHR,EGLL,
    2,EDDF,large_airport,Frankfurt Airport,50.033333,8.570556,364,EU,DE,DE-HE,Frankfurt am Main,yes,EDDF,FRA,EDDF,
    3,KAUS,large_airport,Austin Bergstrom International Airport,30.194500,-97.669899,542,NA,US,US-TX,Austin,yes,KAUS,AUS,KAUS,AUS
    4,LFPG,large_airport,Charles de Gaulle International Airport,49.012798,2.55000,392,EU,FR,FR-IDF,Paris,yes,LFPG,CDG,LFPG,
    5,XX-0001,closed,Some Closed Field,10.0,10.0,100,AF,ZA,ZA-GP,Nowhere,no,,,,
    """

    private static let runwaysCSV = """
    id,airport_ref,airport_ident,length_ft,width_ft,surface,lighted,closed,le_ident,le_latitude_deg,le_longitude_deg,le_elevation_ft,le_heading_degT,le_displaced_threshold_ft,he_ident,he_latitude_deg,he_longitude_deg,he_elevation_ft,he_heading_degT,he_displaced_threshold_ft
    1,1,EGLL,12802,164,ASP,1,0,09L,51.4775,-0.48visible,79,89.6,1007,27R,51.4777,-0.433264,78,269.6,
    2,1,EGLL,12008,164,ASP,1,0,09R,51.4644,-0.482780,77,89.6,,27L,51.4646,-0.434206,76,269.6,
    3,3,KAUS,12250,150,CON,1,0,18L,30.2073,-97.6699,542,180.0,,36R,30.1737,-97.6699,530,0.0,
    4,1,EGLL,9999,150,ASP,1,1,05,51.0,-0.4,70,50.0,,23,51.1,-0.5,70,230.0,
    """

    private static let frequenciesCSV = """
    id,airport_ref,airport_ident,type,description,frequency_mhz
    1,1,EGLL,TWR,Heathrow Tower,118.5
    2,1,EGLL,ATIS,Heathrow ATIS,113.75
    3,3,KAUS,TWR,Austin Tower,121.0
    """

    private static let navaidsCSV = """
    id,filename,ident,name,type,frequency_khz,latitude_deg,longitude_deg,elevation_ft,iso_country,dme_frequency_khz,dme_channel,dme_latitude_deg,dme_longitude_deg,dme_elevation_ft,slaved_variation_deg,magnetic_variation_deg,usageType,power,associated_airport
    1,LON,LON,London,VOR-DME,113600,51.5053,-0.4619,80,GB,113600,83X,51.5053,-0.4619,80,-3.0,-3.0,BOTH,HIGH,EGLL
    2,FFM,FFM,Frankfurt,VOR,114200,50.0806,8.5825,360,DE,,,,,,1.0,1.0,BOTH,HIGH,EDDF
    3,AUS,AUS,Austin,VORTAC,114600,30.2967,-97.6714,540,US,114600,93X,30.2967,-97.6714,540,4.0,4.0,BOTH,HIGH,KAUS
    4,ZZZ,ZZZ,Unknown Kind,SOMETHING,100000,10.0,10.0,0,ZA,,,,,,0.0,0.0,BOTH,LOW,
    """

    private func makeBuilder() throws -> (AeroDatabaseBuilder, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ourairports-test-\(UUID().uuidString).sqlite")
        return (try AeroDatabaseBuilder(path: url.path), url)
    }

    private func ingestor() -> OurAirportsIngestor {
        OurAirportsIngestor(workDirectory: URL(fileURLWithPath: NSTemporaryDirectory())) { _ in }
    }

    private func table(_ csv: String) throws -> CSVTable {
        try CSVTable(data: Data(csv.utf8))
    }

    // MARK: Airports

    @Test func ingestsWorldwideAirports() throws {
        let (builder, url) = try makeBuilder()
        defer { try? FileManager.default.removeItem(at: url) }

        let kept = try ingestor().ingestAirports(table(Self.airportsCSV), excluding: [], into: builder)
        #expect(kept.contains("EGLL"))
        #expect(kept.contains("EDDF"))

        let heathrow = try builder.dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM airport WHERE id = 'EGLL'")
        }
        #expect(heathrow?["name"] == "London Heathrow Airport")
        #expect(heathrow?["country"] == "GB")
        #expect(heathrow?["icao_id"] == "EGLL")
        #expect(heathrow?["elevation_ft"] == 83.0)
        #expect(heathrow?["authority"] == DataAuthority.ourAirports.rawValue)
    }

    /// `iso_region` arrives in exactly the shape `Region.id` uses.
    @Test func isoRegionIsStoredAndSplitIntoState() throws {
        let (builder, url) = try makeBuilder()
        defer { try? FileManager.default.removeItem(at: url) }
        try ingestor().ingestAirports(table(Self.airportsCSV), excluding: [], into: builder)

        let row = try builder.dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT iso_region, state FROM airport WHERE id = 'EGLL'")
        }
        #expect(row?["iso_region"] == "GB-ENG")
        #expect(row?["state"] == "ENG")
    }

    @Test func closedAirportsAreSkipped() throws {
        let (builder, url) = try makeBuilder()
        defer { try? FileManager.default.removeItem(at: url) }
        let kept = try ingestor().ingestAirports(table(Self.airportsCSV), excluding: [], into: builder)

        #expect(kept.contains("XX-0001") == false)
        let count = try builder.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM airport WHERE id = 'XX-0001'")
        }
        #expect(count == 0)
    }

    // MARK: Merge precedence — the regression this design exists to prevent

    @Test func kausAppearsExactlyOnceAndComesFromNASR() throws {
        let (builder, url) = try makeBuilder()
        defer { try? FileManager.default.removeItem(at: url) }

        // Stand in for a NASR run: local ident "AUS", icao_id "KAUS".
        try builder.dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO airport (id, icao_id, name, country, lat, lon, authority)
                VALUES ('AUS', 'KAUS', 'AUSTIN-BERGSTROM INTL', 'US', 30.1945, -97.6699, 'faa')
                """
            )
        }

        let covered = try ingestor().coveredCountries(in: builder)
        #expect(covered == ["US"])

        try ingestor().ingestAirports(table(Self.airportsCSV), excluding: covered, into: builder)

        // The two sources key the same airport differently ("AUS" vs "KAUS"),
        // so nothing would have collided on the primary key — without the
        // country check Austin would now be in the table twice.
        let austinRows = try builder.dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, authority FROM airport WHERE icao_id = 'KAUS' OR id = 'KAUS'")
        }
        #expect(austinRows.count == 1)
        #expect(austinRows.first?["id"] == "AUS")
        #expect(austinRows.first?["authority"] == DataAuthority.faa.rawValue)

        // Non-US airports still arrive.
        let heathrow = try builder.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM airport WHERE id = 'EGLL'")
        }
        #expect(heathrow == 1)
    }

    @Test func withoutExistingDataEveryCountryIsIngested() throws {
        let (builder, url) = try makeBuilder()
        defer { try? FileManager.default.removeItem(at: url) }

        // An OurAirports-only build must still produce US airports.
        let covered = try ingestor().coveredCountries(in: builder)
        #expect(covered.isEmpty)
        let kept = try ingestor().ingestAirports(table(Self.airportsCSV), excluding: covered, into: builder)
        #expect(kept.contains("KAUS"))
    }

    // MARK: Runways, frequencies, navaids

    @Test func runwaysProduceBothEndsAndSkipClosedOnes() throws {
        let (builder, url) = try makeBuilder()
        defer { try? FileManager.default.removeItem(at: url) }
        let kept = try ingestor().ingestAirports(table(Self.airportsCSV), excluding: [], into: builder)
        try ingestor().ingestRunways(table(Self.runwaysCSV), keeping: kept, into: builder)

        let designators = try builder.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT designator FROM runway WHERE airport_id = 'EGLL' ORDER BY designator")
        }
        #expect(designators == ["09L/27R", "09R/27L"])

        let ends = try builder.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT designator FROM runway_end WHERE airport_id = 'EGLL' ORDER BY designator")
        }
        #expect(ends == ["09L", "09R", "27L", "27R"])

        // Dimensions are already in feet upstream — no conversion applied.
        let length = try builder.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT length_ft FROM runway WHERE designator = '09L/27R'")
        }
        #expect(length == 12802)

        let heading = try builder.dbQueue.read { db in
            try Double.fetchOne(db, sql: "SELECT true_heading FROM runway_end WHERE airport_id = 'EGLL' AND designator = '09L'")
        }
        #expect(heading == 89.6)
    }

    @Test func runwaysForSkippedAirportsAreNotOrphaned() throws {
        let (builder, url) = try makeBuilder()
        defer { try? FileManager.default.removeItem(at: url) }
        let kept = try ingestor().ingestAirports(table(Self.airportsCSV), excluding: ["US"], into: builder)
        try ingestor().ingestRunways(table(Self.runwaysCSV), keeping: kept, into: builder)

        let orphans = try builder.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM runway WHERE airport_id = 'KAUS'")
        }
        #expect(orphans == 0)
    }

    @Test func frequenciesConvertMegahertzToKilohertz() throws {
        let (builder, url) = try makeBuilder()
        defer { try? FileManager.default.removeItem(at: url) }
        let kept = try ingestor().ingestAirports(table(Self.airportsCSV), excluding: [], into: builder)
        try ingestor().ingestFrequencies(table(Self.frequenciesCSV), keeping: kept, into: builder)

        let tower = try builder.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT freq_khz FROM frequency WHERE airport_id = 'EGLL' AND facility_type = 'TWR'")
        }
        #expect(tower == 118_500)

        let atis = try builder.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT freq_khz FROM frequency WHERE airport_id = 'EGLL' AND facility_type = 'ATIS'")
        }
        #expect(atis == 113_750)
    }

    @Test func navaidTypesMapToTheSchemaVocabulary() throws {
        let (builder, url) = try makeBuilder()
        defer { try? FileManager.default.removeItem(at: url) }
        try ingestor().ingestNavaids(table(Self.navaidsCSV), excluding: [], into: builder)

        let london = try builder.dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM navaid WHERE id = 'LON'")
        }
        #expect(london?["type"] == "vorDme")
        #expect(london?["freq_khz"] == 113_600)
        #expect(london?["channel"] == "83X")
        #expect(london?["authority"] == DataAuthority.ourAirports.rawValue)

        // An unrecognised type is dropped rather than stored as something we
        // cannot render.
        let unknown = try builder.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM navaid WHERE id = 'ZZZ'")
        }
        #expect(unknown == 0)
    }

    @Test func navaidsRespectCoveredCountries() throws {
        let (builder, url) = try makeBuilder()
        defer { try? FileManager.default.removeItem(at: url) }
        try ingestor().ingestNavaids(table(Self.navaidsCSV), excluding: ["US"], into: builder)

        let austin = try builder.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM navaid WHERE id = 'AUS'")
        }
        #expect(austin == 0)
    }

    // MARK: Schema v4

    @Test func schemaVersionIsFour() {
        #expect(AeroDatabaseBuilder.schemaVersion == 4)
    }

    @Test func searchFoldsDiacritics() throws {
        let (builder, url) = try makeBuilder()
        defer { try? FileManager.default.removeItem(at: url) }
        try builder.dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO airport (id, icao_id, name, city, country, lat, lon, authority)
                VALUES ('EDDK', 'EDDK', 'Köln Bonn Airport', 'Köln', 'DE', 50.86, 7.14, 'ourAirports')
                """
            )
        }
        try builder.buildIndexes()

        // Typing "Koln" on a keyboard without an umlaut must still find it.
        let hits = try builder.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT airport_id FROM airport_fts WHERE airport_fts MATCH 'Koln'")
        }
        #expect(hits == ["EDDK"])
    }

    @Test func buildIndexesIsIdempotent() throws {
        let (builder, url) = try makeBuilder()
        defer { try? FileManager.default.removeItem(at: url) }
        try ingestor().ingestAirports(table(Self.airportsCSV), excluding: [], into: builder)

        // Two ingests in one run (NASR then OurAirports) means buildIndexes may
        // be called after each; duplicated FTS rows would double search hits.
        try builder.buildIndexes()
        try builder.buildIndexes()

        let hits = try builder.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM airport_fts WHERE airport_fts MATCH 'Heathrow'")
        }
        #expect(hits == 1)
    }
}
