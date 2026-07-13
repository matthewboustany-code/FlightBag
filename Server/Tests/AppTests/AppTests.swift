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
                let manifest = try response.content.decode(DownloadManifest.self)
                #expect(manifest.cycle == DataCycle.current().id)
                #expect(manifest.products.isEmpty)
            }
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
