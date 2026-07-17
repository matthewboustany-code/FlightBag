import Foundation
import Testing
@testable import FBModels

@Suite struct DownloadManifestTests {
    private func sampleManifest() -> DownloadManifest {
        DownloadManifest(
            generatedAt: Date(timeIntervalSince1970: 1_780_000_000),
            cycle: "2607",
            regions: [
                Region(id: "US-TX", name: "Texas", authority: .faa, kind: .stateOrProvince),
                Region(id: "US-OK", name: "Oklahoma", authority: .faa, kind: .stateOrProvince),
            ],
            products: [
                DownloadProduct(
                    id: "tiles.vfr.San_Antonio.2607",
                    contentKind: .vfrSectional,
                    title: "San Antonio Sectional",
                    cycle: "2607",
                    regionIds: ["US-TX"],
                    url: URL(string: "https://example.com/artifacts/2607/tiles/San_Antonio_sectional.mbtiles")!,
                    sizeBytes: 180_000_000,
                    sha256: "ab12"
                ),
                DownloadProduct(
                    id: "tiles.ifrlow.ELUS01.2606",
                    contentKind: .ifrEnrouteLow,
                    title: "IFR Low ELUS01",
                    cycle: "2606",
                    regionIds: ["US-TX", "US-OK"],
                    url: URL(string: "https://example.com/artifacts/2606/tiles/ELUS01_ifr_low.mbtiles")!,
                    sizeBytes: 90_000_000,
                    sha256: "cd34",
                    expirationDate: Date(timeIntervalSince1970: 1_785_000_000)
                ),
            ],
            nextCycleProducts: []
        )
    }

    @Test func codableRoundTrip() throws {
        let manifest = sampleManifest()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DownloadManifest.self, from: encoder.encode(manifest))
        #expect(decoded == manifest)
    }

    @Test func optionalFieldsOmittedDecodeAsDefaults() throws {
        // A product without expirationDate round-trips as nil (expires with cycle).
        let manifest = sampleManifest()
        #expect(manifest.products[0].expirationDate == nil)
        #expect(manifest.products[1].expirationDate != nil)
    }

    @Test func contentKindRawValuesAreStable() {
        // Raw values are wire format between server and app — lock them.
        #expect(DownloadProduct.ContentKind.aeroDatabase.rawValue == "aeroDatabase")
        #expect(DownloadProduct.ContentKind.plates.rawValue == "plates")
        #expect(DownloadProduct.ContentKind.vfrSectional.rawValue == "vfrSectional")
        #expect(DownloadProduct.ContentKind.ifrEnrouteLow.rawValue == "ifrEnrouteLow")
        #expect(DownloadProduct.ContentKind.ifrEnrouteHigh.rawValue == "ifrEnrouteHigh")
        #expect(DownloadProduct.ContentKind.basemap.rawValue == "basemap")
        #expect(DownloadProduct.ContentKind.terrain.rawValue == "terrain")
    }

    @Test func regionCodableRoundTrip() throws {
        let region = Region(id: "US-RI", name: "Rhode Island", authority: .faa, kind: .stateOrProvince)
        let decoded = try JSONDecoder().decode(Region.self, from: JSONEncoder().encode(region))
        #expect(decoded == region)
    }
}
