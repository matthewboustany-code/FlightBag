import Foundation
import Testing
import GRDB
import FBModels
@testable import FlightBag

@Suite struct ProcedureQueryTests {
    /// Throwaway sqlite with the v3 procedure tables and a two-transition SID.
    private func makeDatabase(schemaVersion: Int) throws -> (AeroDatabase, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("proc-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                INSERT INTO meta VALUES ('cycle', '2607'), ('schema_version', '\(schemaVersion)');
                CREATE TABLE procedure (id INTEGER PRIMARY KEY, airport_id TEXT NOT NULL, ident TEXT NOT NULL, kind TEXT NOT NULL);
                CREATE TABLE procedure_leg (
                    procedure_id INTEGER NOT NULL, transition_kind TEXT NOT NULL, transition_ident TEXT,
                    seq INTEGER NOT NULL, fix_ident TEXT NOT NULL, lat REAL NOT NULL, lon REAL NOT NULL,
                    path_term TEXT, alt_desc TEXT, alt1_ft INTEGER, speed_kt INTEGER
                );
                INSERT INTO procedure VALUES (1, 'KAUS', 'AEROZ2', 'sid');
                INSERT INTO procedure_leg VALUES
                    (1, 'common', NULL, 10, 'AMUSE', 30.45, -98.29, 'IF', '+', 5000, NULL),
                    (1, 'common', NULL, 20, 'AEROZ', 30.70, -98.86, 'TF', NULL, NULL, NULL),
                    (1, 'enroute', 'SJT', 10, 'AEROZ', 30.70, -98.86, 'IF', NULL, NULL, NULL),
                    (1, 'enroute', 'SJT', 20, 'SJT', 31.37, -100.45, 'TF', NULL, NULL, NULL);
                """)
        }
        return (try AeroDatabase(path: url.path), url)
    }

    @Test func queriesProceduresAndLegs() async throws {
        let (db, url) = try makeDatabase(schemaVersion: 3)
        defer { try? FileManager.default.removeItem(at: url) }

        let procedures = try await db.procedures(airportId: "AUS", icaoId: "KAUS")
        #expect(procedures == [AeroDatabase.ProcedureSummary(ident: "AEROZ2", kind: "sid")])

        let legs = try await db.procedureLegs(airportId: "AUS", icaoId: "KAUS", ident: "AEROZ2")
        #expect(legs.count == 4)
        #expect(legs.first?.fixIdent == "AMUSE")
    }

    @Test func schemaGateHidesProceduresOnOldDatabases() async throws {
        let (db, url) = try makeDatabase(schemaVersion: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let procedures = try await db.procedures(airportId: "AUS", icaoId: "KAUS")
        #expect(procedures.isEmpty)
    }

    @Test func assemblesBranchesWithSharedJunction() async throws {
        let (db, url) = try makeDatabase(schemaVersion: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        let legs = try await db.procedureLegs(airportId: "AUS", icaoId: "KAUS", ident: "AEROZ2")

        let procedure = ActiveMapProcedure(airportDisplayId: "KAUS", ident: "AEROZ2", kind: "sid", legs: legs)
        #expect(procedure.label == "KAUS AEROZ2 (SID)")
        #expect(procedure.branches.count == 2)
        #expect(procedure.branches.map(\.label).sorted() == ["SJT", "common"])
        // AEROZ appears in both branches but only once as an annotation point.
        #expect(procedure.uniquePoints.map(\.identifier).sorted() == ["AEROZ", "AMUSE", "SJT"])
    }
}
