import Foundation
import Testing
import FBModels
@testable import FBProviders

struct FixtureHTTPClient: HTTPGetting {
    let data: Data

    func get(_ url: URL) async throws -> Data {
        data
    }
}

@Suite struct AviationWeatherGovProviderTests {
    private func fixture(_ name: String) throws -> Data {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json")
            ?? Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
        return try Data(contentsOf: #require(url))
    }

    @Test func decodesRealMetarJSON() async throws {
        let provider = AviationWeatherGovProvider(http: FixtureHTTPClient(data: try fixture("metar_kaus")))
        let metars = try await provider.metars(for: [ICAOIdentifier("KAUS"), ICAOIdentifier("KHYI")])
        #expect(metars.count == 2)

        let kaus = try #require(metars.first)
        #expect(kaus.station.rawValue == "KAUS")
        #expect(kaus.temperatureC == 33.3)
        #expect(kaus.windDirectionDegrees == 170)
        #expect(kaus.windGustKt == 18)
        #expect(kaus.visibilitySM == 10)
        #expect(kaus.visibilityIsAtLeast)
        #expect(kaus.flightCategory == .vfr)
        #expect(kaus.clouds.count == 2)
        #expect(kaus.raw.hasPrefix("KAUS 121753Z"))

        // Variable wind + low ceiling: wdir is the string "VRB", no fltCat in
        // the JSON so the category must be computed (BKN008 → IFR).
        let khyi = try #require(metars.last)
        #expect(khyi.windIsVariable)
        #expect(khyi.windDirectionDegrees == nil)
        #expect(khyi.ceilingFeet == 800)
        #expect(khyi.flightCategory == .ifr)
    }

    @Test func localDraftFilingRejectsInvalidPlan() async throws {
        let service = LocalDraftFilingService()
        let receipt = try await service.file(.init(), as: .local)
        #expect(receipt.status == .rejected)
    }
}

@Suite struct FBWindsParserTests {
    @Test func parsesRealProduct() throws {
        let url = try #require(Bundle.module.url(forResource: "windtemp_dfw", withExtension: "txt", subdirectory: "Fixtures"))
        let text = try String(contentsOf: url, encoding: .utf8)
        let stations = FBWindsParser.parse(text)
        #expect(stations.count > 10)

        let dal = try #require(stations.first { $0.identifier == "DAL" })
        // "DAL 9900 2907+15 …": 3000 ft light and variable, 6000 ft 290°/7 kt +15 °C.
        let low = try #require(dal.entries[3000])
        #expect(low.fromDegrees == nil && low.speedKt == 0)
        let mid = try #require(dal.entries[6000])
        #expect(mid.fromDegrees == 290 && mid.speedKt == 7 && mid.temperatureC == 15)
        // Above 24 000 ft signs are dropped: "311230" = 310°/12 kt, −30 °C.
        let high = try #require(dal.entries[30000])
        #expect(high.fromDegrees == 310 && high.speedKt == 12 && high.temperatureC == -30)

        // entryNearest picks the closest level (7000 → 6000 ft).
        #expect(dal.entryNearest(altitudeFt: 7000)?.fromDegrees == mid.fromDegrees)
    }

    @Test func decodesHighSpeedGroups() {
        // dd 51–86 encodes direction −50 with speed +100: 7512 = 250°/112 kt.
        let entry = FBWindsParser.parseGroup("7512-30")
        #expect(entry?.fromDegrees == 250)
        #expect(entry?.speedKt == 112)
        #expect(entry?.temperatureC == -30)
        // 36 encodes 360°.
        #expect(FBWindsParser.parseGroup("3610")?.fromDegrees == 360)
        #expect(FBWindsParser.parseGroup("") == nil)
    }
}
