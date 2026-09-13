import Foundation
import GRDB
import Testing
@testable import FlightBag

@Suite struct MapAirportTierTests {
    private func seedDatabase() throws -> AeroDatabase {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: "aero", withExtension: "sqlite")
            ?? Bundle.main.url(forResource: "aero", withExtension: "sqlite"))
        return try AeroDatabase(path: url.path)
    }

    @Test func kausIsTierZero() async throws {
        let db = try seedDatabase()
        let airports = try await db.mapAirportsNear(
            latitude: 30.19, longitude: -97.67, spanDegrees: 1.0, maxTier: 0, limit: 20
        )
        let aus = try #require(airports.first { $0.icaoId == "KAUS" })
        #expect(aus.tier == 0)
    }

    @Test func maxTierZeroExcludesSmallFields() async throws {
        let db = try seedDatabase()
        let majors = try await db.mapAirportsNear(
            latitude: 30.19, longitude: -97.67, spanDegrees: 1.0, maxTier: 0, limit: 80
        )
        let all = try await db.mapAirportsNear(
            latitude: 30.19, longitude: -97.67, spanDegrees: 1.0, maxTier: 2, limit: 80
        )
        #expect(majors.allSatisfy { $0.tier == 0 })
        #expect(all.count > majors.count)
        #expect(all.contains { $0.tier == 2 })
    }
}

@Suite struct MapAirportStoredTierTests {
    /// A schema-6 database whose stored tier disagrees with what the
    /// frequency and runway tables would compute, so the test can tell which
    /// one the query read.
    private func schemaSixDatabase() throws -> (AeroDatabase, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tier-v6-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                INSERT INTO meta VALUES ('schema_version', '6'), ('cycle', '2609');
                CREATE TABLE airport (id TEXT PRIMARY KEY, icao_id TEXT, name TEXT NOT NULL,
                    lat REAL NOT NULL, lon REAL NOT NULL, kind TEXT NOT NULL, tier INTEGER);
                CREATE VIRTUAL TABLE airport_rtree USING rtree(id, min_lat, max_lat, min_lon, max_lon);
                CREATE TABLE frequency (airport_id TEXT NOT NULL, use TEXT);
                CREATE TABLE runway (airport_id TEXT NOT NULL, length_ft INTEGER);
                INSERT INTO airport VALUES ('AUS', 'KAUS', 'Austin', 30.19, -97.67, 'airport', 0);
                INSERT INTO airport VALUES ('3R3', NULL, 'Airpark', 30.26, -97.55, 'airport', NULL);
                INSERT INTO airport_rtree SELECT rowid, lat, lat, lon, lon FROM airport;
                """)
        }
        try queue.close()
        return (try AeroDatabase(path: url.path), url)
    }

    @Test func schemaSixReadsTheStoredTier() async throws {
        let (db, url) = try schemaSixDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let airports = try await db.mapAirportsNear(latitude: 30.2, longitude: -97.6, spanDegrees: 1, maxTier: 2, limit: 10)
        // No tower or runway rows: a computed tier would say 2.
        #expect(airports.first { $0.id == "AUS" }?.tier == 0)
        // A row the ingest never tiered reads as the least prominent.
        #expect(airports.first { $0.id == "3R3" }?.tier == 2)
    }
}

private final class BundleToken {}
