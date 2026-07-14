import Foundation
import Testing
import FBModels
@testable import FBProviders

@Suite struct AirspaceProviderTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "geojson", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    @Test func decodesClassAirspaceGeoJSON() throws {
        let collection = try JSONDecoder().decode(GeoJSONFeatureCollection.self, from: try fixture("class_airspace"))
        let airspaces = collection.features.compactMap { $0.toAirspace() }
        #expect(airspaces.count == 12)

        let categories = Set(airspaces.map(\.category))
        #expect(categories.contains(.classC))
        #expect(categories.contains(.classD))

        let austinD = try #require(airspaces.first { $0.name.contains("AUSTIN") && $0.category == .classD })
        #expect(austinD.lowerText == "SFC")
        #expect(austinD.upperText.contains("ft"))
        for airspace in airspaces {
            #expect(!airspace.polygons.isEmpty)
            #expect(airspace.polygons.allSatisfy { $0.count >= 3 })
        }
    }

    @Test func decodesSpecialUseAirspaceGeoJSON() throws {
        let collection = try JSONDecoder().decode(GeoJSONFeatureCollection.self, from: try fixture("sua_airspace"))
        let airspaces = collection.features.compactMap { $0.toAirspace() }
        #expect(airspaces.count == 8)

        let categories = Set(airspaces.map(\.category))
        #expect(categories.contains(.restricted))
        #expect(categories.contains(.warning))
        #expect(airspaces.contains { $0.name.hasPrefix("R-6312") || $0.name == "R-6312" })
        #expect(airspaces.contains { $0.name.hasPrefix("W-228") })
    }

    @Test func requestsOnlySelectedCategories() async throws {
        // A provider asked only for SUA categories must not query Class_Airspace.
        let recorder = RecordingHTTPClient(data: Data("{\"features\":[]}".utf8))
        let provider = FAAAirspaceProvider(http: recorder)
        _ = try await provider.airspaces(categories: [.restricted, .warning], minLat: 29, minLon: -99, maxLat: 31, maxLon: -96)
        let urls = await recorder.requestedURLs()
        #expect(urls.count == 1)
        #expect(urls[0].absoluteString.contains("Special_Use_Airspace"))
        #expect(urls[0].absoluteString.contains("TYPE_CODE"))
    }
}

actor RecordingHTTPClient: HTTPGetting {
    private let data: Data
    private var urls: [URL] = []

    init(data: Data) {
        self.data = data
    }

    func get(_ url: URL) async throws -> Data {
        urls.append(url)
        return data
    }

    func requestedURLs() -> [URL] {
        urls
    }
}
