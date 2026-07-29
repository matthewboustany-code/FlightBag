import Foundation
import Testing
import FBModels
import FBFISB
@testable import FlightBag

@Suite struct FISBNotamConversionTests {
    private func report(_ record: String) -> FISBTextReport {
        FISBTextReport.parse(record: record)
    }

    @Test func parsesTheNotamSeriesToken() {
        #expect(report("NOTAM-D KAUS 01/005 TWY A CLSD").kind == .notamD)
        #expect(report("NOTAM-FDC KAUS 1/2345 SPECIAL NOTICE").kind == .notamFDC)
        #expect(report("NOTAM-TFR KAUS 4/1234 AIRSPACE").kind == .notamTFR)
        #expect(report("METAR KAUS 151953Z 17010KT").kind == .metar)
    }

    @Test func onlyNotamKindsReportAsNotams() {
        #expect(FISBTextReport.Kind.notamD.isNotam)
        #expect(FISBTextReport.Kind.notamFDC.isNotam)
        #expect(FISBTextReport.Kind.notamTFR.isNotam)
        #expect(FISBTextReport.Kind.notam.isNotam)
        #expect(!FISBTextReport.Kind.metar.isNotam)
        #expect(!FISBTextReport.Kind.taf.isNotam)
        #expect(!FISBTextReport.Kind.pirep.isNotam)
        #expect(!FISBTextReport.Kind.other.isNotam)
    }

    @Test func splitsStationNumberAndBody() throws {
        let notam = try #require(report("NOTAM-D KAUS 01/005 TWY A CLSD BTN TWY B AND TWY F").toNotam())
        #expect(notam.location.rawValue == "KAUS")
        #expect(notam.id == "01/005")
        #expect(notam.text == "TWY A CLSD BTN TWY B AND TWY F")
        // The uplink carries no end time, so validity is deliberately unstated.
        #expect(notam.endIsEstimated)
        #expect(notam.effectiveEnd == nil)
        #expect(notam.isActive())
    }

    @Test func handlesAlphanumericNotamNumbers() throws {
        let notam = try #require(report("NOTAM-D EGLL A0123/26 RWY 09L/27R CLSD").toNotam())
        #expect(notam.id == "A0123/26")
        #expect(notam.text == "RWY 09L/27R CLSD")
    }

    @Test func synthesisesAStableIdWhenNoNumberIsPresent() throws {
        // Two uplinks of the same notice must collapse, not accumulate.
        let first = try #require(report("NOTAM-D KAUS RWY 18L CLSD").toNotam())
        let second = try #require(report("NOTAM-D KAUS RWY 18L CLSD").toNotam())
        #expect(first.id == second.id)
        #expect(first.text == "RWY 18L CLSD")
    }

    @Test func rejectsNonNotamAndBodylessRecords() {
        #expect(report("METAR KAUS 151953Z 17010KT").toNotam() == nil)
        #expect(report("NOTAM-D KAUS").toNotam() == nil)
        #expect(report("NOTAM-D KAUS 01/005").toNotam() == nil)
    }
}

/// Serialized: every test here shares one on-disk cache file and the
/// `serverBaseURL` default, so running them concurrently races.
@Suite(.serialized) struct NotamStoreTests {
    /// Isolates each test from the on-disk cache the initialiser loads.
    private func emptyStore() async -> NotamStore {
        let store = NotamStore()
        await store.removeAllForTesting()
        return store
    }

    @Test func fisbIngestAddsNotamsKeyedByStation() async throws {
        let store = await emptyStore()
        await store.ingestFISB(reports: [
            FISBTextReport.parse(record: "NOTAM-D KAUS 01/005 TWY A CLSD"),
            FISBTextReport.parse(record: "NOTAM-D KDAL 02/001 RWY 13L CLSD"),
        ])

        let austin = await store.cachedForTesting("KAUS")
        #expect(austin?.notams.count == 1)
        #expect(austin?.source == .fisb)
        #expect(await store.cachedForTesting("KDAL")?.notams.count == 1)
    }

    @Test func repeatedUplinksDoNotAccumulateDuplicates() async throws {
        let store = await emptyStore()
        let record = FISBTextReport.parse(record: "NOTAM-D KAUS 01/005 TWY A CLSD")
        let start = Date()
        for i in 0..<5 {
            await store.ingestFISB(reports: [record], receivedAt: start.addingTimeInterval(Double(i)))
        }
        #expect(await store.cachedForTesting("KAUS")?.notams.count == 1)
    }

    @Test func uplinkNeverAgeRegressesAnEntry() async throws {
        let store = await emptyStore()
        let now = Date()
        await store.ingestFISB(
            reports: [FISBTextReport.parse(record: "NOTAM-D KAUS 01/005 TWY A CLSD")],
            receivedAt: now
        )
        // A rebroadcast stamped earlier must not roll the entry backwards.
        await store.ingestFISB(
            reports: [FISBTextReport.parse(record: "NOTAM-D KAUS 01/009 RWY 36 CLSD")],
            receivedAt: now.addingTimeInterval(-600)
        )
        let entry = await store.cachedForTesting("KAUS")
        #expect(entry?.notams.count == 1)
        #expect(entry?.fetchedAt == now)
    }

    @Test func uplinkDoesNotOverwriteRicherServerData() async throws {
        let store = await emptyStore()
        let detailed = Notam(
            id: "01/005",
            location: ICAOIdentifier("KAUS"),
            text: "TWY A CLSD",
            qCode: "QMXLC",
            coordinate: Coordinate(latitude: 30.19, longitude: -97.67),
            radiusNM: 5
        )
        await store.seedForTesting("KAUS", notams: [detailed], source: .server)
        await store.ingestFISB(reports: [FISBTextReport.parse(record: "NOTAM-D KAUS 01/005 TWY A CLSD")])

        let stored = await store.cachedForTesting("KAUS")?.notams.first
        // The server copy carries geometry the uplink can't; keep it.
        #expect(stored?.mapCircle != nil)
        #expect(stored?.qCode == "QMXLC")
    }

    @Test func noServerConfiguredIsReportedDistinctlyFromEmpty() async throws {
        let store = await emptyStore()
        let previous = UserDefaults.standard.string(forKey: ServerConfig.defaultsKey)
        UserDefaults.standard.removeObject(forKey: ServerConfig.defaultsKey)
        defer { if let previous { UserDefaults.standard.set(previous, forKey: ServerConfig.defaultsKey) } }

        let result = await store.notams(for: ICAOIdentifier("KAUS"))
        #expect(result.availability == .noServerConfigured)
        #expect(result.notams.isEmpty)
    }

    @Test func cachedNotamsSurviveAnUnreachableServer() async throws {
        let store = await emptyStore()
        await store.seedForTesting(
            "KAUS",
            notams: [Notam(id: "01/005", location: ICAOIdentifier("KAUS"), text: "TWY A CLSD")],
            source: .server
        )
        let previous = UserDefaults.standard.string(forKey: ServerConfig.defaultsKey)
        // Port 1 refuses connections immediately.
        UserDefaults.standard.set("http://127.0.0.1:1", forKey: ServerConfig.defaultsKey)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: ServerConfig.defaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: ServerConfig.defaultsKey) }
        }

        let result = await store.notams(for: ICAOIdentifier("KAUS"))
        #expect(result.availability == .unreachable)
        // The cached NOTAM is still shown — an empty list would read as
        // "nothing is wrong at KAUS".
        #expect(result.notams.count == 1)
        #expect(result.isStale)
    }

    @Test func briefingKeepsRouteOrderAndCollapsesRepeats() async throws {
        let store = await emptyStore()
        for id in ["KAUS", "KDAL", "KHOU"] {
            await store.seedForTesting(
                id,
                notams: [Notam(id: "01/001", location: ICAOIdentifier(id), text: "AD CLSD")],
                source: .server
            )
        }
        let previous = UserDefaults.standard.string(forKey: ServerConfig.defaultsKey)
        UserDefaults.standard.removeObject(forKey: ServerConfig.defaultsKey)
        defer { if let previous { UserDefaults.standard.set(previous, forKey: ServerConfig.defaultsKey) } }

        // KAUS repeats (departure and return); it must appear once, first.
        let briefings = await store.briefing(for: [
            ICAOIdentifier("KAUS"), ICAOIdentifier("KDAL"),
            ICAOIdentifier("KHOU"), ICAOIdentifier("KAUS"),
        ])
        #expect(briefings.map(\.station.rawValue) == ["KAUS", "KDAL", "KHOU"])
    }

    @Test func briefingIgnoresEmptyIdentifiers() async throws {
        let store = await emptyStore()
        let briefings = await store.briefing(for: [ICAOIdentifier(""), ICAOIdentifier("  ")])
        #expect(briefings.isEmpty)
    }

    @Test func activeNotamsSortAheadOfExpiredOnes() async throws {
        let store = await emptyStore()
        let now = Date()
        await store.seedForTesting("KAUS", notams: [
            Notam(id: "01/001", location: ICAOIdentifier("KAUS"), text: "expired",
                  effectiveStart: now.addingTimeInterval(-7_200), effectiveEnd: now.addingTimeInterval(-3_600)),
            Notam(id: "01/002", location: ICAOIdentifier("KAUS"), text: "active old",
                  effectiveStart: now.addingTimeInterval(-86_400)),
            Notam(id: "01/003", location: ICAOIdentifier("KAUS"), text: "active new",
                  effectiveStart: now.addingTimeInterval(-600)),
        ], source: .server)

        let previous = UserDefaults.standard.string(forKey: ServerConfig.defaultsKey)
        UserDefaults.standard.removeObject(forKey: ServerConfig.defaultsKey)
        defer { if let previous { UserDefaults.standard.set(previous, forKey: ServerConfig.defaultsKey) } }

        let result = await store.notams(for: ICAOIdentifier("KAUS"))
        #expect(result.notams.map(\.id) == ["01/003", "01/002", "01/001"])
    }
}
