import Foundation
import Testing
import FBModels
@testable import FBProviders

/// Enum mappings here come from openAIP's published OpenAPI schema
/// (`/api/system/specs/v1/schema.json`), so these tests pin a documented
/// contract rather than a guess.
@Suite struct OpenAIPAirspaceProviderTests {
    private static let sample = """
    {"items":[
      {"_id":"a1","name":"LONDON CTR","type":4,"icaoClass":3,"country":"GB",
       "lowerLimit":{"value":0,"unit":1,"referenceDatum":0},
       "upperLimit":{"value":2500,"unit":1,"referenceDatum":1},
       "geometry":{"type":"Polygon","coordinates":[[[-0.5,51.4],[-0.3,51.4],[-0.3,51.6],[-0.5,51.6],[-0.5,51.4]]]}},
      {"_id":"a2","name":"EDR-12 DANGER","type":2,"icaoClass":8,"country":"DE",
       "lowerLimit":{"value":0,"unit":1,"referenceDatum":0},
       "upperLimit":{"value":100,"unit":6},
       "geometry":{"type":"Polygon","coordinates":[[[8.0,50.0],[8.2,50.0],[8.2,50.2],[8.0,50.2],[8.0,50.0]]]}},
      {"_id":"a3","name":"P-1 PROHIBITED","type":3,"icaoClass":8,"country":"FR",
       "lowerLimit":{"value":0,"unit":1,"referenceDatum":0},
       "upperLimit":{"value":3000,"unit":1,"referenceDatum":1},
       "geometry":{"type":"Polygon","coordinates":[[[2.0,48.8],[2.2,48.8],[2.2,49.0],[2.0,49.0],[2.0,48.8]]]}},
      {"_id":"a4","name":"CLASS E","type":0,"icaoClass":4,"country":"GB",
       "geometry":{"type":"Polygon","coordinates":[[[1.0,52.0],[1.2,52.0],[1.2,52.2],[1.0,52.2],[1.0,52.0]]]}}
    ]}
    """

    private func provider(_ json: String = sample, key: String? = "test-key") -> OpenAIPAirspaceProvider {
        OpenAIPAirspaceProvider(http: FixtureHTTPClient(data: Data(json.utf8)), apiKey: key)
    }

    private func allCategories() -> Set<Airspace.Category> { Set(Airspace.Category.allCases) }

    @Test func decodesAirspacesAndMapsCategories() async throws {
        let result = try await provider().airspaces(
            categories: allCategories(), minLat: 48, minLon: -1, maxLat: 53, maxLon: 9
        )
        // Class E has no FlightBag category and drops out.
        #expect(result.count == 3)
        #expect(result.contains { $0.name == "LONDON CTR" && $0.category == .classD })
        #expect(result.contains { $0.name == "EDR-12 DANGER" && $0.category == .danger })
        #expect(result.contains { $0.name == "P-1 PROHIBITED" && $0.category == .prohibited })
    }

    /// GeoJSON is [lon, lat]; Coordinate is (lat, lon). Getting this backwards
    /// puts European airspace in the Indian Ocean.
    @Test func coordinatesAreNotTransposed() async throws {
        let result = try await provider().airspaces(
            categories: allCategories(), minLat: 48, minLon: -1, maxLat: 53, maxLon: 9
        )
        let london = try #require(result.first { $0.name == "LONDON CTR" })
        let point = try #require(london.polygons.first?.first)
        #expect(point.latitude == 51.4)
        #expect(point.longitude == -0.5)
    }

    @Test func sUATypeWinsOverUnclassifiedICAOClass() {
        // SUA volumes report icaoClass 8 ("unclassified"); the type carries
        // the meaning, so it has to take precedence.
        #expect(OpenAIPAirspaceProvider.category(icaoClass: 8, type: 1) == .restricted)
        #expect(OpenAIPAirspaceProvider.category(icaoClass: 8, type: 2) == .danger)
        #expect(OpenAIPAirspaceProvider.category(icaoClass: 8, type: 3) == .prohibited)
        #expect(OpenAIPAirspaceProvider.category(icaoClass: 8, type: 18) == .warning)
    }

    @Test func icaoClassesMapToControlledAirspace() {
        #expect(OpenAIPAirspaceProvider.category(icaoClass: 1, type: 0) == .classB)
        #expect(OpenAIPAirspaceProvider.category(icaoClass: 2, type: 0) == .classC)
        #expect(OpenAIPAirspaceProvider.category(icaoClass: 3, type: 0) == .classD)
        // A/E/F/G have no FlightBag category — nil, not a wrong guess.
        #expect(OpenAIPAirspaceProvider.category(icaoClass: 0, type: 0) == nil)
        #expect(OpenAIPAirspaceProvider.category(icaoClass: 4, type: 0) == nil)
        #expect(OpenAIPAirspaceProvider.category(icaoClass: 6, type: 0) == nil)
    }

    @Test func requestedCategoriesAreHonoured() async throws {
        let result = try await provider().airspaces(
            categories: [.prohibited], minLat: 48, minLon: -1, maxLat: 53, maxLon: 9
        )
        #expect(result.count == 1)
        #expect(result.first?.category == .prohibited)
    }

    /// A blank layer must never be mistaken for "no airspace here".
    @Test func missingKeyThrowsRatherThanReturningEmpty() async {
        await #expect(throws: OpenAIPError.self) {
            _ = try await provider(key: nil).airspaces(
                categories: allCategories(), minLat: 48, minLon: -1, maxLat: 53, maxLon: 9
            )
        }
        await #expect(throws: OpenAIPError.self) {
            _ = try await provider(key: "").airspaces(
                categories: allCategories(), minLat: 48, minLon: -1, maxLat: 53, maxLon: 9
            )
        }
    }

    // MARK: Altitude limits

    @Test func altitudeLimitsRenderAsPublishedText() async throws {
        let result = try await provider().airspaces(
            categories: allCategories(), minLat: 48, minLon: -1, maxLat: 53, maxLon: 9
        )
        let london = try #require(result.first { $0.name == "LONDON CTR" })
        #expect(london.lowerText == "0 ft SFC")
        #expect(london.upperText == "2500 ft MSL")

        let danger = try #require(result.first { $0.name == "EDR-12 DANGER" })
        #expect(danger.upperText == "FL 100")
    }

    /// The response object's unit/datum codes are not in openAIP's published
    /// schema, so an unrecognised one must degrade to unbounded — which
    /// AltitudeBand never hides — rather than assert a wrong altitude.
    @Test func unrecognisedLimitUnitsBecomeUnbounded() {
        let unknown = OpenAIPLimit(value: 4000, unit: 99, referenceDatum: 99)
        #expect(unknown.text == "")
        #expect(AltitudeBand.feet(fromText: unknown.text) == nil)

        let noValue = OpenAIPLimit(value: nil, unit: 1, referenceDatum: 1)
        #expect(noValue.text == "")
    }

    @Test func publishedLimitTextParsesBackToFeet() {
        // The text has to round-trip through the altitude filter the map uses.
        #expect(AltitudeBand.feet(fromText: OpenAIPLimit(value: 2500, unit: 1, referenceDatum: 1).text) == 2500)
        #expect(AltitudeBand.feet(fromText: OpenAIPLimit(value: 100, unit: 6, referenceDatum: nil).text) == 10_000)
    }
}
