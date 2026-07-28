import Testing
import Foundation
@testable import FBModels

struct ChartSourceTests {
    private func ofmSource(regionIds: [String] = ["OFM-ED"]) -> ChartSource {
        ChartSource(
            id: "ofm-vfr",
            authority: .openFlightMaps,
            contentKind: .vfrSectional,
            title: "open flightmaps VFR",
            regionIds: regionIds
        )
    }

    // MARK: - Resolution

    /// With no manifest — first launch, or offline before the first fetch —
    /// the map must still stream, which is the whole reason the FAA
    /// descriptors stay compiled in.
    @Test func fallsBackToBuiltInFAASourcesWithoutAManifest() throws {
        let source = try #require(ChartSource.streamingSource(for: .vfrSectional, manifestSources: []))
        #expect(source.authority == .faa)
        #expect(source.streaming?.urlTemplate.contains("VFR_Sectional") == true)
    }

    /// The point of moving sources into the manifest: the server can correct a
    /// service URL or zoom range without an app release.
    @Test func manifestSourceOverridesTheBuiltIn() throws {
        let replacement = ChartSource(
            id: "faa-vfr-sectional",
            authority: .faa,
            contentKind: .vfrSectional,
            title: "VFR Sectional",
            streaming: .init(urlTemplate: "https://example.test/{z}/{x}/{y}.png", minimumZoom: 6, maximumZoom: 11)
        )
        let source = try #require(
            ChartSource.streamingSource(for: .vfrSectional, manifestSources: [replacement])
        )
        #expect(source.streaming?.urlTemplate == "https://example.test/{z}/{x}/{y}.png")
        #expect(source.streaming?.zoomRange == 6...11)
    }

    /// A download-only authority must never be handed to the streaming
    /// overlay. open flightmaps publishes MBTiles and runs no tile service, so
    /// selecting it to stream would leave the map blank over Europe with no
    /// indication why.
    @Test func sourcesWithoutStreamingAreNeverSelected() throws {
        let source = try #require(
            ChartSource.streamingSource(
                for: .vfrSectional,
                regionIds: ["OFM-ED"],
                manifestSources: [ofmSource()]
            )
        )
        #expect(source.authority == .faa, "should fall through to a source that actually streams")
        #expect(source.streaming != nil)
    }

    /// A regional source wins over a global one, so European coverage can
    /// override a worldwide default where it applies.
    @Test func regionalStreamingSourceBeatsAGlobalOne() throws {
        let regional = ChartSource(
            id: "eu-vfr",
            authority: .openFlightMaps,
            contentKind: .vfrSectional,
            title: "EU VFR",
            regionIds: ["OFM-ED"],
            streaming: .init(urlTemplate: "https://eu.test/{z}/{x}/{y}.png", minimumZoom: 7, maximumZoom: 12)
        )
        let chosen = try #require(
            ChartSource.streamingSource(for: .vfrSectional, regionIds: ["OFM-ED"], manifestSources: [regional])
        )
        #expect(chosen.id == "eu-vfr")

        // Outside its regions the same source must not be picked.
        let elsewhere = try #require(
            ChartSource.streamingSource(for: .vfrSectional, regionIds: ["US-TX"], manifestSources: [regional])
        )
        #expect(elsewhere.authority == .faa)
    }

    @Test func matchesOnContentKind() throws {
        let high = try #require(ChartSource.streamingSource(for: .ifrEnrouteHigh, manifestSources: []))
        #expect(high.streaming?.zoomRange == 5...9)
        let low = try #require(ChartSource.streamingSource(for: .ifrEnrouteLow, manifestSources: []))
        #expect(low.streaming?.zoomRange == 7...12)
        // Not a chart layer — nothing streams a plate bundle.
        #expect(ChartSource.streamingSource(for: .plates, manifestSources: []) == nil)
    }

    // MARK: - Attribution

    /// Attribution is a licence condition for both open flightmaps and
    /// openAIP, so a source that renders without it is used out of licence.
    @Test func licensedSourcesCarryAttribution() {
        #expect(ofmSource().attribution?.contains("open flightmaps") == true)
        // FAA data is public domain and needs none.
        #expect(ChartSource.faaBuiltIns.allSatisfy { $0.attribution == nil })
    }

    // MARK: - Manifest compatibility

    /// A manifest written before chart sources existed must still decode —
    /// otherwise an app update would brick every already-published manifest.
    @Test func manifestWithoutChartSourcesStillDecodes() throws {
        let json = Data("""
        {"generatedAt":"2026-07-28T00:00:00Z","cycle":"2607","products":[]}
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(DownloadManifest.self, from: json)
        #expect(manifest.chartSources.isEmpty)
        #expect(manifest.regions.isEmpty)
        #expect(manifest.cycle == "2607")
    }

    @Test func manifestRoundTripsChartSources() throws {
        let manifest = DownloadManifest(
            generatedAt: Date(timeIntervalSince1970: 1_780_000_000),
            cycle: "2607",
            products: [],
            chartSources: ChartSource.faaBuiltIns + [ofmSource()]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DownloadManifest.self, from: encoder.encode(manifest))
        #expect(decoded.chartSources.count == 4)
        #expect(decoded.chartSources.contains { $0.authority == .openFlightMaps })
    }

    /// `DataAuthority` decodes unknown values to `.unknown`; a chart source
    /// naming an authority this build has never heard of must not take the
    /// whole manifest down with it.
    @Test func unknownAuthorityInAChartSourceDecodesSafely() throws {
        let json = Data("""
        {"id":"x","authority":"someFutureAgency","contentKind":"vfrSectional","title":"X","regionIds":[]}
        """.utf8)
        let source = try JSONDecoder().decode(ChartSource.self, from: json)
        #expect(source.authority == .unknown)
    }
}
