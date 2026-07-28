import Testing
import VaporTesting
import FBModels
@testable import App

@Suite struct AppTests {
    @Test func manifestReturnsCurrentCycle() async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app)
            try await app.testing().test(.GET, "v1/manifest") { response async throws in
                #expect(response.status == .ok)
                // Decodes whether the server has a generated manifest.json
                // (products populated) or is a fresh checkout (empty).
                let manifest = try response.content.decode(DownloadManifest.self)
                #expect(DataCycle(id: manifest.cycle) != nil)
            }
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    /// The test environment has no FAA credentials, which is also the state a
    /// self-hoster starts in. It must degrade to an explicit "not configured"
    /// rather than a 500 or, worse, an empty list that reads as "no NOTAMs".
    @Test func notamsReportUnconfiguredWithoutCredentials() async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app)
            try await app.testing().test(.GET, "v1/airports/KAUS/notams") { response async throws in
                #expect(response.status == .ok)
                let body = try response.content.decode(AirportNotamsResponse.self)
                #expect(body.configured == false)
                #expect(body.notams.isEmpty)
                #expect(body.station.rawValue == "KAUS")
            }
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}

@Suite struct NotamCacheTests {
    private func response(_ station: String) -> AirportNotamsResponse {
        AirportNotamsResponse(
            station: ICAOIdentifier(station),
            configured: true,
            notams: [Notam(id: "01/005", location: ICAOIdentifier(station), text: "TWY A CLSD")]
        )
    }

    @Test func servesWithinTheTTLAndExpiresAfter() async throws {
        let cache = NotamCache(ttl: 900)
        let start = Date()
        await cache.store("KAUS", response("KAUS"), now: start)

        #expect(await cache.cached("KAUS", now: start.addingTimeInterval(899)) != nil)
        #expect(await cache.cached("KAUS", now: start.addingTimeInterval(901)) == nil)
    }

    @Test func doesNotServeOneStationsNotamsForAnother() async throws {
        let cache = NotamCache()
        await cache.store("KAUS", response("KAUS"))
        #expect(await cache.cached("KDAL") == nil)
    }
}
