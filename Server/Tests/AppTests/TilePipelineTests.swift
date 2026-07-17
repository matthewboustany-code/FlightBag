import Foundation
import Testing
import GRDB
import FBModels
@testable import App

@Suite struct TileSourceTests {
    // Cycle 2607 is effective 2026-07-09 — a live enroute edition date.
    private let cycle = DataCycle(id: "2607")!

    @Test func sectionalURLAndNaming() {
        let source = TilePipeline.Source.sectional(chart: "San_Antonio")
        #expect(source.remoteURL(for: cycle).absoluteString == "https://aeronav.faa.gov/visual/07-09-2026/sectional-files/San_Antonio.zip")
        #expect(source.artifactFileName == "San_Antonio_sectional.mbtiles")
        #expect(!source.isEnroute)
    }

    @Test func enrouteURLsAndNaming() {
        let low = TilePipeline.Source.enrouteLow(panel: 1)
        #expect(low.remoteURL(for: cycle).absoluteString == "https://aeronav.faa.gov/enroute/07-09-2026/enr_l01.zip")
        #expect(low.artifactFileName == "ENR_L01_ifr_low.mbtiles")
        #expect(low.isEnroute)

        let high = TilePipeline.Source.enrouteHigh(panel: 12)
        #expect(high.remoteURL(for: cycle).absoluteString == "https://aeronav.faa.gov/enroute/07-09-2026/enr_h12.zip")
        #expect(high.artifactFileName == "ENR_H12_ifr_high.mbtiles")
    }

    @Test func basemapSourceNamingAndBehavior() {
        let basemap = TilePipeline.Source.naturalEarthBasemap
        #expect(basemap.artifactFileName == "basemap_natural_earth.mbtiles")
        #expect(basemap.artifactFileName.hasPrefix("basemap"))  // ManifestBuilder + app classify by this prefix
        #expect(!basemap.isEnroute)
        #expect(!basemap.needsPaletteExpansion)  // NE2 is RGB, not paletted
        #expect(basemap.remoteURL(for: cycle).absoluteString == "https://naciscdn.org/naturalearth/10m/raster/NE2_HR_LC_SR_W.zip")
    }

    @Test func enrouteFileNamesSatisfyAppKindClassifier() {
        // The app classifies by these substrings (ChartKind.kind(forFileName:));
        // suffix discipline is what keeps a chart named "...High..." from
        // misclassifying (plan risk R5).
        #expect(TilePipeline.Source.enrouteLow(panel: 3).artifactFileName.contains("_ifr_low"))
        #expect(TilePipeline.Source.enrouteHigh(panel: 3).artifactFileName.contains("_ifr_high"))
        #expect(TilePipeline.Source.sectional(chart: "X").artifactFileName.contains("_sectional"))
    }
}

@Suite struct RegionBoundsTests {
    @Test func sanAntonioBoxHitsTexasOnly() {
        // Approximate San Antonio sectional bounds: south-central TX.
        let box = RegionBounds.Box(minLon: -102.0, minLat: 28.0, maxLon: -97.0, maxLat: 32.0)
        let ids = RegionBounds.regionIds(intersecting: box)
        #expect(ids.contains("US-TX"))
        #expect(!ids.contains("US-CA"))
    }

    @Test func widePanelSpansSeveralStates() {
        // A panel across the TX/OK/AR/LA seam.
        let box = RegionBounds.Box(minLon: -98.0, minLat: 31.0, maxLon: -91.0, maxLat: 35.0)
        let ids = RegionBounds.regionIds(intersecting: box)
        #expect(Set(["US-TX", "US-OK", "US-AR", "US-LA"]).isSubset(of: Set(ids)))
        #expect(!ids.contains("US-WA"))
    }

    @Test func touchingEdgesDoNotCountAsIntersection() {
        // Strictly east of every state box's maxLon.
        let atlantic = RegionBounds.Box(minLon: -60.0, minLat: 30.0, maxLon: -50.0, maxLat: 40.0)
        #expect(RegionBounds.regionIds(intersecting: atlantic).isEmpty)
    }

    @Test func readsBoundsFromRealMBTiles() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("bounds-test-\(UUID().uuidString).mbtiles").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE metadata (name TEXT, value TEXT)")
            try db.execute(sql: "INSERT INTO metadata VALUES ('bounds', '-102.0,28.0,-97.0,32.0')")
        }
        let box = try #require(RegionBounds.mbtilesBounds(at: URL(fileURLWithPath: path)))
        #expect(box.minLon == -102.0)
        #expect(box.maxLat == 32.0)
    }

    @Test func garbageFileYieldsNoBounds() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("garbage-\(UUID().uuidString).mbtiles")
        defer { try? FileManager.default.removeItem(at: url) }
        try "not a database".write(to: url, atomically: true, encoding: .utf8)
        #expect(RegionBounds.mbtilesBounds(at: url) == nil)
    }
}

@Suite struct PlateBundlerQueryTests {
    /// aero.sqlite fixture with two airports in different states.
    private func makeFixture() throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("plates-test-\(UUID().uuidString).sqlite").path
        let builder = try AeroDatabaseBuilder(path: path)
        try builder.setMeta(cycle: DataCycle(id: "2607")!)
        try builder.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO airport (id, name, state, lat, lon) VALUES
                    ('AUS', 'Austin-Bergstrom Intl', 'TX', 30.19, -97.67),
                    ('PVD', 'T F Green Intl', 'RI', 41.72, -71.43);
                INSERT INTO plate (airport_id, chart_code, chart_name, pdf_name, cycle, url) VALUES
                    ('AUS', 'IAP', 'ILS RWY 18L', '00048il18l.pdf', '2607', 'https://aeronav.faa.gov/d-tpp/2607/00048il18l.pdf'),
                    ('AUS', 'APD', 'AIRPORT DIAGRAM', '00048ad.pdf', '2607', 'https://aeronav.faa.gov/d-tpp/2607/00048ad.pdf'),
                    ('PVD', 'IAP', 'ILS RWY 05', '00341il5.pdf', '2607', 'https://aeronav.faa.gov/d-tpp/2607/00341il5.pdf');
                """)
        }
        return path
    }

    @Test func plateRowsFilterByState() throws {
        let path = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let texas = try PlateBundler.plateRows(databasePath: path, stateCode: "TX")
        #expect(texas.count == 2)
        #expect(texas.allSatisfy { $0.airportId == "AUS" })
        // Airport diagrams are plates too — chart_code APD rides along.
        #expect(texas.contains { $0.pdfName == "00048ad.pdf" })

        let rhodeIsland = try PlateBundler.plateRows(databasePath: path, stateCode: "RI")
        #expect(rhodeIsland.map(\.pdfName) == ["00341il5.pdf"])
        #expect(try PlateBundler.plateRows(databasePath: path, stateCode: "WY").isEmpty)
    }

    @Test func databaseCycleComesFromMeta() throws {
        let path = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(try PlateBundler.databaseCycle(databasePath: path) == "2607")
    }
}
