import Testing
import Foundation
import FBModels
@testable import App

struct OpenFlightMapsTests {
    // MARK: - Source URLs

    /// open flightmaps versions its snapshots by the same AIRAC numbering
    /// `DataCycle` uses, which is why no cycle translation is needed anywhere
    /// in this ingestor.
    @Test func buildsTheSnapshotURLForAFIR() {
        let url = OpenFlightMapsIngestor.sourceURL(cycle: DataCycle(id: "2607")!, fir: "ed")
        #expect(url.absoluteString == "https://snapshots.openflightmaps.org/live/2607/tiles/ed/noninteractive/epsg3857/ed_256@2x.mbtiles")
    }

    @Test func artifactNamesKeepTheSectionalSuffix() {
        // The suffix is what ChartCatalog.tileSuffixKinds and the app's
        // filename fallback both classify on; dropping it would make an OFM
        // chart unrecognizable to anything reading it without a manifest.
        #expect(OpenFlightMapsIngestor.artifactFileName(fir: "ed") == "OFM_ED_sectional.mbtiles")
        #expect(OpenFlightMapsIngestor.artifactFileName(fir: "lsas").hasSuffix("_sectional.mbtiles"))
    }

    // MARK: - Catalog

    @Test func firArtifactsResolveToTheirOwnRegion() {
        #expect(ChartCatalog.openFlightMapsFIR(forArtifact: "OFM_ED_sectional.mbtiles") == "ed")
        #expect(ChartCatalog.regionIds(forTileArtifact: "OFM_ED_sectional.mbtiles") == ["OFM-ED"])
        #expect(ChartCatalog.title(forTileArtifact: "OFM_ED_sectional.mbtiles") == "Germany VFR (open flightmaps)")
    }

    /// An FAA artifact must not be mistaken for an OFM one, and an unknown FIR
    /// must not invent a region.
    @Test func nonOFMArtifactsAreLeftAlone() {
        #expect(ChartCatalog.openFlightMapsFIR(forArtifact: "San_Antonio_sectional.mbtiles") == nil)
        #expect(ChartCatalog.openFlightMapsFIR(forArtifact: "OFM_ZZZZ_sectional.mbtiles") == nil)
        #expect(ChartCatalog.regionIds(forTileArtifact: "OFM_ZZZZ_sectional.mbtiles") == nil)
    }

    @Test func regionsAreRegisteredForEveryPublishedFIR() {
        let regionIds = Set(ChartCatalog.regions.map(\.id))
        for (fir, _) in ChartCatalog.openFlightMapsFIRs {
            #expect(regionIds.contains("OFM-\(fir.uppercased())"), "missing region for \(fir)")
        }
        // US regions must survive the merge.
        #expect(regionIds.contains("US-TX"))
    }

    @Test func openFlightMapsRegionsCarryTheirAuthority() {
        let germany = ChartCatalog.region(id: "OFM-ED")
        #expect(germany?.authority == .openFlightMaps)
        #expect(germany?.kind == .custom)
        #expect(ChartCatalog.region(id: "US-TX")?.authority == .faa)
    }

    // MARK: - Published chart sources

    /// open flightmaps runs no tile service, so its descriptor must not claim
    /// streaming — the map would show nothing and blame the network.
    @Test func openFlightMapsSourceIsDownloadOnly() throws {
        let ofm = try #require(ChartCatalog.chartSources.first { $0.authority == .openFlightMaps })
        #expect(ofm.streaming == nil)
        #expect(!ofm.regionIds.isEmpty)
        #expect(ofm.attribution?.contains("open flightmaps") == true)
    }

    @Test func faaSourcesAreStillPublished() {
        let faa = ChartCatalog.chartSources.filter { $0.authority == .faa }
        #expect(faa.count == 3)
        #expect(faa.allSatisfy { $0.streaming != nil })
    }
}
