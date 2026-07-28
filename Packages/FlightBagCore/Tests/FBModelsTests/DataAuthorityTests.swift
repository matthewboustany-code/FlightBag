import Foundation
import Testing
@testable import FBModels

@Suite struct DataAuthorityTests {
    @Test func rawValuesAreStable() {
        // These are wire format (manifest JSON) and on-disk format (aero.sqlite
        // `authority` columns). Changing one silently orphans existing rows.
        #expect(DataAuthority.faa.rawValue == "faa")
        #expect(DataAuthority.eurocontrol.rawValue == "eurocontrol")
        #expect(DataAuthority.navCanada.rawValue == "navCanada")
        #expect(DataAuthority.ourAirports.rawValue == "ourAirports")
        #expect(DataAuthority.openAIP.rawValue == "openAIP")
        #expect(DataAuthority.openFlightMaps.rawValue == "openFlightMaps")
        #expect(DataAuthority.unknown.rawValue == "unknown")
    }

    @Test func unknownAuthorityDecodesInsteadOfThrowing() throws {
        let data = Data("\"somethingWeHaveNotShippedYet\"".utf8)
        let decoded = try JSONDecoder().decode(DataAuthority.self, from: data)
        #expect(decoded == .unknown)
    }

    @Test func knownAuthoritiesStillDecodeExactly() throws {
        for authority in DataAuthority.known {
            let data = try JSONEncoder().encode(authority)
            #expect(try JSONDecoder().decode(DataAuthority.self, from: data) == authority)
        }
    }

    @Test func unknownIsExcludedFromKnown() {
        #expect(DataAuthority.known.contains(.unknown) == false)
        #expect(DataAuthority.known.count == DataAuthority.allCases.count - 1)
    }

    /// The regression this whole custom decoder exists to prevent: one
    /// unfamiliar authority must not take the entire manifest down with it.
    @Test func manifestWithAnUnfamiliarAuthorityStillDecodesFully() throws {
        let json = """
        {
          "generatedAt": "2026-07-27T00:00:00Z",
          "cycle": "2607",
          "regions": [
            {"id": "US-TX", "name": "Texas", "authority": "faa", "kind": "stateOrProvince"},
            {"id": "DE", "name": "Germany", "authority": "someFutureAuthority", "kind": "country"}
          ],
          "products": [],
          "nextCycleProducts": []
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(DownloadManifest.self, from: Data(json.utf8))

        #expect(manifest.regions.count == 2)
        // The region we *do* understand survives intact.
        #expect(manifest.regions[0].authority == .faa)
        #expect(manifest.regions[1].authority == .unknown)
        #expect(manifest.regions[1].id == "DE")
        #expect(manifest.regions[1].kind == .country)
    }

    @Test func licensedSourcesCarryAttribution() {
        // openAIP and open flightmaps both require attribution; shipping their
        // data without it breaches the licence.
        #expect(DataAuthority.openAIP.attribution != nil)
        #expect(DataAuthority.openFlightMaps.attribution != nil)
        #expect(DataAuthority.ourAirports.attribution != nil)
        #expect(DataAuthority.faa.attribution == nil)
    }
}
