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
