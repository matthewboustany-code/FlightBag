import Foundation
import GRDB
import Testing
@testable import App

@Suite struct AeroDatabaseSchemaTests {
    private func builtDatabase() throws -> (AeroDatabaseBuilder, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("schema-test-\(UUID().uuidString).sqlite")
        let builder = try AeroDatabaseBuilder(path: url.path)
        try builder.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO airport (id, icao_id, name, lat, lon, kind) VALUES
                    ('AUS', 'KAUS', 'Austin-Bergstrom', 30.19, -97.67, 'airport'),
                    ('EDC', 'KEDC', 'Austin Executive', 30.40, -97.57, 'airport'),
                    ('GTU', 'KGTU', 'Georgetown', 30.68, -97.68, 'airport'),
                    ('3R3', NULL, 'Austin Airpark', 30.26, -97.55, 'airport');
                INSERT INTO frequency (airport_id, freq_khz, use) VALUES ('AUS', 121000, 'TWR'), ('GTU', 120625, 'TWR');
                INSERT INTO runway (airport_id, designator, length_ft) VALUES
                    ('AUS', '18L/36R', 9000), ('EDC', '13/31', 6025), ('GTU', '18/36', 4100), ('3R3', '17/35', 2200);
                INSERT INTO navaid (id, type, name, lat, lon) VALUES ('CWK', 'VORTAC', 'CENTEX', 30.38, -97.53);
                INSERT INTO fix (id, lat, lon) VALUES ('BLEWE', 30.1, -97.9);
                """)
            // A worldwide spread, so the planner sees what real ingests give
            // it; a one-row table is cheaper to scan than to index.
            for i in 0..<2_000 {
                let lat = Double(i % 180) - 90, lon = Double((i * 7) % 360) - 180
                try db.execute(sql: "INSERT INTO fix (id, lat, lon) VALUES (?, ?, ?)", arguments: ["F\(i)", lat, lon])
                try db.execute(sql: "INSERT INTO navaid (id, lat, lon) VALUES (?, ?, ?)", arguments: ["N\(i)", lat, lon])
                try db.execute(
                    sql: "INSERT INTO airway_point (airway_id, location, seq, point_id, lat, lon) VALUES (?, 'C', ?, ?, ?, ?)",
                    arguments: ["V\(i % 50)", i, "F\(i)", lat, lon])
            }
        }
        try builder.buildIndexes()
        return (builder, url)
    }

    @Test func buildIndexesPrecomputesTheMapTier() throws {
        let (builder, url) = try builtDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let tiers = try builder.dbQueue.read { db in
            try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: "SELECT id, tier FROM airport").map {
                ($0["id"] as String, $0["tier"] as Int)
            })
        }
        // Towered + 9000 ft; 6025 ft untowered; towered + 4100 ft; neither.
        #expect(tiers == ["AUS": 0, "EDC": 1, "GTU": 1, "3R3": 2])
    }

    @Test func viewportQueriesUseTheLatLonIndexes() throws {
        let (builder, url) = try builtDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        func plan(_ sql: String) throws -> String {
            try builder.dbQueue.read { db in
                try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql).map { $0["detail"] as String }.joined(separator: " | ")
            }
        }
        #expect(try plan("SELECT id FROM navaid WHERE lat BETWEEN 30 AND 31 AND lon BETWEEN -98 AND -97")
            .contains("idx_navaid_latlon"))
        #expect(try plan("SELECT id FROM fix WHERE lat BETWEEN 30 AND 31 AND lon BETWEEN -98 AND -97")
            .contains("idx_fix_latlon"))
        #expect(try plan("SELECT DISTINCT airway_id FROM airway_point WHERE location = 'C' AND lat BETWEEN 30 AND 31 AND lon BETWEEN -98 AND -97")
            .contains("idx_airway_point_loc"))
    }
}
