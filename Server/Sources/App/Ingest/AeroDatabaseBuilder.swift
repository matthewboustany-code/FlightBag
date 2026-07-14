import Foundation
import GRDB
import FBModels

/// Creates and populates the per-cycle `aero.sqlite` the app consumes.
/// Schema is normalized and authority-neutral: a future international
/// ingestor writes the same tables.
struct AeroDatabaseBuilder {
    let dbQueue: DatabaseQueue

    init(path: String) throws {
        // Start fresh each build; the artifact is immutable once published.
        try? FileManager.default.removeItem(atPath: path)
        dbQueue = try DatabaseQueue(path: path)
        try createSchema()
    }

    /// Open an already-built database to append to it (e.g. d-TPP after NASR).
    init(existingPath: String) throws {
        dbQueue = try DatabaseQueue(path: existingPath)
        // Re-running d-TPP ingestion replaces plate data rather than duplicating it.
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM plate")
        }
    }

    private func createSchema() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE meta (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
                CREATE TABLE airport (
                    id TEXT PRIMARY KEY,
                    icao_id TEXT,
                    name TEXT NOT NULL,
                    city TEXT,
                    state TEXT,
                    country TEXT NOT NULL DEFAULT 'US',
                    lat REAL NOT NULL,
                    lon REAL NOT NULL,
                    elevation_ft REAL,
                    mag_var REAL,
                    tpa_ft REAL,
                    site_type TEXT,
                    facility_use TEXT,
                    ownership TEXT,
                    status TEXT,
                    authority TEXT NOT NULL DEFAULT 'faa'
                );
                CREATE VIRTUAL TABLE airport_fts USING fts5(
                    ident, name, city,
                    airport_id UNINDEXED,
                    tokenize = 'unicode61'
                );
                CREATE VIRTUAL TABLE airport_rtree USING rtree(
                    id, min_lat, max_lat, min_lon, max_lon
                );
                CREATE TABLE runway (
                    airport_id TEXT NOT NULL,
                    designator TEXT NOT NULL,
                    length_ft INTEGER,
                    width_ft INTEGER,
                    surface TEXT
                );
                CREATE INDEX idx_runway_airport ON runway(airport_id);
                CREATE TABLE runway_end (
                    airport_id TEXT NOT NULL,
                    runway_designator TEXT NOT NULL,
                    designator TEXT NOT NULL,
                    true_heading REAL,
                    lat REAL,
                    lon REAL,
                    elevation_ft REAL,
                    displaced_threshold_ft INTEGER,
                    ils_type TEXT,
                    right_pattern INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX idx_runway_end_airport ON runway_end(airport_id);
                CREATE TABLE frequency (
                    airport_id TEXT NOT NULL,
                    facility TEXT,
                    facility_type TEXT,
                    freq_khz INTEGER NOT NULL,
                    use TEXT,
                    call TEXT,
                    sector TEXT
                );
                CREATE INDEX idx_frequency_airport ON frequency(airport_id);
                CREATE TABLE navaid (
                    id TEXT NOT NULL,
                    type TEXT,
                    name TEXT,
                    lat REAL NOT NULL,
                    lon REAL NOT NULL,
                    freq_khz INTEGER,
                    channel TEXT,
                    authority TEXT NOT NULL DEFAULT 'faa'
                );
                CREATE INDEX idx_navaid_id ON navaid(id);
                CREATE TABLE fix (
                    id TEXT NOT NULL,
                    lat REAL NOT NULL,
                    lon REAL NOT NULL,
                    use_code TEXT,
                    icao_region TEXT,
                    authority TEXT NOT NULL DEFAULT 'faa'
                );
                CREATE INDEX idx_fix_id ON fix(id);
                CREATE TABLE plate (
                    airport_id TEXT NOT NULL,
                    chart_code TEXT NOT NULL,
                    chart_name TEXT NOT NULL,
                    pdf_name TEXT NOT NULL,
                    cycle TEXT NOT NULL,
                    url TEXT NOT NULL
                );
                CREATE INDEX idx_plate_airport ON plate(airport_id);
                CREATE TABLE airway (
                    id TEXT NOT NULL,
                    location TEXT NOT NULL,
                    designation TEXT,
                    point_count INTEGER NOT NULL,
                    authority TEXT NOT NULL DEFAULT 'faa',
                    PRIMARY KEY (id, location)
                );
                CREATE TABLE airway_point (
                    airway_id TEXT NOT NULL,
                    location TEXT NOT NULL,
                    seq INTEGER NOT NULL,
                    point_id TEXT NOT NULL,
                    point_type TEXT,
                    lat REAL,
                    lon REAL
                );
                CREATE INDEX idx_airway_point ON airway_point(airway_id, location, seq);
                """)
        }
    }

    /// Bumped when the schema gains tables the app depends on, so the app can
    /// prefer a bundled seed over an installed database of the same cycle.
    /// 2: airway/airway_point tables.
    static let schemaVersion = 2

    func setMeta(cycle: DataCycle) throws {
        try dbQueue.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO meta VALUES ('cycle', ?)", arguments: [cycle.id])
            try db.execute(sql: "INSERT OR REPLACE INTO meta VALUES ('schema_version', ?)", arguments: [String(Self.schemaVersion)])
            try db.execute(
                sql: "INSERT OR REPLACE INTO meta VALUES ('cycle_effective', ?)",
                arguments: [ISO8601DateFormatter().string(from: cycle.effectiveDate)]
            )
            try db.execute(sql: "INSERT OR REPLACE INTO meta VALUES ('generated_at', ?)", arguments: [ISO8601DateFormatter().string(from: Date())])
        }
    }

    /// Populate the FTS and R*Tree indexes from the airport table. Run once
    /// after all airports are inserted.
    func buildIndexes() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO airport_fts (ident, name, city, airport_id)
                SELECT COALESCE(icao_id, '') || ' ' || id, name, COALESCE(city, ''), id FROM airport;
                """)
            try db.execute(sql: """
                INSERT INTO airport_rtree (id, min_lat, max_lat, min_lon, max_lon)
                SELECT rowid, lat, lat, lon, lon FROM airport;
                """)
            try db.execute(sql: "ANALYZE")
        }
    }

    func vacuum() throws {
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
        }
    }
}
