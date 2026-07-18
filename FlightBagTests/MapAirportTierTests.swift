import Foundation
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

private final class BundleToken {}
