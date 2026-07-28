import Foundation
import Testing
import FBModels
@testable import FBProviders

@Suite struct AdvisoryProviderTests {
    private func fixture(_ name: String, _ ext: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    @Test func decodesRealAirSigmets() async throws {
        let provider = AviationWeatherGovProvider(http: FixtureHTTPClient(data: try fixture("airsigmet", "json")))
        let advisories = try await provider.airSigmets()
        #expect(!advisories.isEmpty)
        for advisory in advisories {
            #expect(advisory.polygon.count >= 3)
            #expect(advisory.validTo > advisory.validFrom)
        }
        #expect(advisories.contains { $0.hazard == "CONVECTIVE" && $0.kind == .sigmet })
    }

    /// Captured from the live `isigmet` product. The international feed has a
    /// different shape from the domestic one — no `airSigmetType`, FIR instead
    /// of station, plain `base`/`top` instead of `altitudeLow1`/`altitudeHi1`.
    @Test func decodesRealInternationalSigmets() async throws {
        let provider = AviationWeatherGovProvider(http: FixtureHTTPClient(data: try fixture("isigmet", "json")))
        let advisories = try await provider.internationalSigmets()
        #expect(advisories.count == 3)
        for advisory in advisories {
            #expect(advisory.polygon.count >= 3)
            #expect(advisory.validTo > advisory.validFrom)
            // The international product carries only SIGMETs.
            #expect(advisory.kind == .sigmet)
        }
    }

    /// Altitudes must survive: decoding this feed with the domestic model
    /// would silently drop every one, since the field names differ.
    @Test func internationalSigmetsKeepTheirAltitudes() async throws {
        let provider = AviationWeatherGovProvider(http: FixtureHTTPClient(data: try fixture("isigmet", "json")))
        let advisories = try await provider.internationalSigmets()

        let volcanic = try #require(advisories.first { $0.hazard.contains("VA") })
        #expect(volcanic.altitudeLowFt == 0)
        #expect(volcanic.altitudeHiFt == 9000)

        // A missing base is unbounded, not zero — AltitudeBand treats nil as
        // "never hide", which is the safe direction.
        let thunderstorms = try #require(advisories.first { $0.hazard.contains("TS") })
        #expect(thunderstorms.altitudeLowFt == nil)
        #expect(thunderstorms.altitudeHiFt == 50_000)
    }

    /// "EMBD TS" (embedded — invisible on radar until you're in it) is a
    /// materially different brief from plain "TS", so the qualifier is kept.
    @Test func internationalSigmetsRetainTheirQualifiers() async throws {
        let provider = AviationWeatherGovProvider(http: FixtureHTTPClient(data: try fixture("isigmet", "json")))
        let advisories = try await provider.internationalSigmets()

        #expect(advisories.contains { $0.hazard == "EMBD TS" })
        #expect(advisories.contains { $0.hazard == "SEV TURB" })
        // Volcanic ash carries the volcano name in the same field.
        #expect(advisories.contains { $0.hazard == "LEWOTOBI VA" })
    }

    @Test func internationalSigmetIdsAreDistinctPerAdvisory() async throws {
        let provider = AviationWeatherGovProvider(http: FixtureHTTPClient(data: try fixture("isigmet", "json")))
        let advisories = try await provider.internationalSigmets()
        // The store merges domestic and international on id; collisions there
        // would silently drop hazards.
        #expect(Set(advisories.map(\.id)).count == advisories.count)
    }

    @Test func decodesRealGAirmets() async throws {
        let provider = AviationWeatherGovProvider(http: FixtureHTTPClient(data: try fixture("gairmet", "json")))
        let airmets = try await provider.graphicalAirmets()
        #expect(!airmets.isEmpty)
        // All three product families appear in the captured cycle.
        let products = Set(airmets.map(\.product))
        #expect(products == Set(GraphicalAirmet.Product.allCases))
        // Freezing-level contours are lines, not areas.
        for airmet in airmets where airmet.hazard == "FZLVL" && airmet.polygon.first == airmet.polygon.last {
            #expect(!airmet.polygon.isEmpty)
        }
        for airmet in airmets {
            #expect(airmet.polygon.count >= 2)
        }
    }

    @Test func parsesTFRDetailXML() throws {
        let entry = TFRListEntry(notamId: "6/5504", type: "VIP", description: "Austin, TX, Tuesday, July 14, 2026 Local")
        let tfr = try #require(FAATFRProvider.parseDetail(try fixture("tfr_detail", "xml"), entry: entry))

        #expect(tfr.id == "6/5504")
        #expect(tfr.type == "VIP")
        #expect(tfr.areas.count == 1)

        let area = try #require(tfr.areas.first)
        #expect(area.name == "Area A")
        // The merged polygon wins over the raw circle primitive.
        #expect(area.polygon.count == 37)
        #expect(area.floorText == "0 FT")
        #expect(area.ceilingText == "4999 FT")
        // Vertices land near Austin.
        for vertex in area.polygon {
            #expect(abs(vertex.latitude - 30.3) < 1.0)
            #expect(abs(vertex.longitude - -97.7) < 1.0)
        }
    }
}

extension TFRListEntry {
    init(notamId: String, type: String?, description: String?) {
        let json = """
        {"notam_id": "\(notamId)", "type": "\(type ?? "")", "description": "\(description ?? "")"}
        """
        self = try! JSONDecoder().decode(TFRListEntry.self, from: Data(json.utf8))
    }
}
