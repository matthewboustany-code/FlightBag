import Foundation

/// Where a chart layer's tiles come from, and on whose terms.
///
/// The app used to answer this itself: `ChartKind` carried an FAA ArcGIS
/// service name and the zoom range that service publishes, so "which chart
/// types exist" and "who serves them" were the same enum. That works exactly
/// as long as there is one authority. Adding a second — open flightmaps for
/// Europe, say — meant editing the app, shipping a build, and waiting for
/// users to install it before any new coverage appeared.
///
/// Carrying sources in the manifest instead makes a new chart authority a
/// server-side change: publish a descriptor, and clients that already know how
/// to read one pick it up on their next manifest fetch. The app keeps a
/// built-in FAA descriptor purely so the map still streams before it has ever
/// reached the server.
public struct ChartSource: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var authority: DataAuthority
    /// Which chart layer this feeds. Only the chart kinds are meaningful here
    /// — a `basemap` or `plates` product is not something the chart picker
    /// can select.
    public var contentKind: DownloadProduct.ContentKind
    public var title: String
    /// Regions this source covers, matching `Region.id`. Empty means it
    /// applies wherever nothing more specific does, which is how the FAA
    /// descriptor behaves for the US.
    public var regionIds: [String]
    /// Live tiles, when the authority publishes a public tile service. nil
    /// means download-only: open flightmaps ships per-FIR MBTiles rather than
    /// serving tiles, so its charts work offline but cannot be streamed.
    public var streaming: Streaming?

    /// A public XYZ raster tile service.
    public struct Streaming: Codable, Sendable, Hashable {
        /// Template containing `{z}`, `{x}` and `{y}`, as `MKTileOverlay` wants.
        public var urlTemplate: String
        /// Zoom levels the service actually publishes. Outside this range a
        /// raster layer draws nothing — MapKit will not resample on its own —
        /// so the range is part of the contract, not a hint.
        public var minimumZoom: Int
        public var maximumZoom: Int

        public init(urlTemplate: String, minimumZoom: Int, maximumZoom: Int) {
            self.urlTemplate = urlTemplate
            self.minimumZoom = minimumZoom
            self.maximumZoom = maximumZoom
        }

        public var zoomRange: ClosedRange<Int> {
            minimumZoom...max(minimumZoom, maximumZoom)
        }
    }

    public init(
        id: String,
        authority: DataAuthority,
        contentKind: DownloadProduct.ContentKind,
        title: String,
        regionIds: [String] = [],
        streaming: Streaming? = nil
    ) {
        self.id = id
        self.authority = authority
        self.contentKind = contentKind
        self.title = title
        self.regionIds = regionIds
        self.streaming = streaming
    }

    /// Attribution the source's licence requires, if any. Delegates to
    /// `DataAuthority` so one place decides what each licence demands.
    public var attribution: String? { authority.attribution }
}

extension ChartSource {
    /// The FAA's public raster services, which the app falls back to when it
    /// has no manifest yet — first launch, or offline before the first fetch.
    ///
    /// These stay compiled in rather than manifest-only because losing chart
    /// streaming entirely when the server is unreachable would be a worse
    /// failure than the staleness of a hardcoded URL. Zoom ranges are what the
    /// services publish; IFR High stops at 9, which is why the map has to
    /// synthesize deeper levels rather than draw nothing.
    public static let faaBuiltIns: [ChartSource] = [
        ChartSource(
            id: "faa-vfr-sectional",
            authority: .faa,
            contentKind: .vfrSectional,
            title: "VFR Sectional",
            streaming: Streaming(urlTemplate: faaTemplate("VFR_Sectional"), minimumZoom: 8, maximumZoom: 12)
        ),
        ChartSource(
            id: "faa-ifr-low",
            authority: .faa,
            contentKind: .ifrEnrouteLow,
            title: "IFR Enroute Low",
            streaming: Streaming(urlTemplate: faaTemplate("IFR_AreaLow"), minimumZoom: 7, maximumZoom: 12)
        ),
        ChartSource(
            id: "faa-ifr-high",
            authority: .faa,
            contentKind: .ifrEnrouteHigh,
            title: "IFR Enroute High",
            streaming: Streaming(urlTemplate: faaTemplate("IFR_High"), minimumZoom: 5, maximumZoom: 9)
        ),
    ]

    static func faaTemplate(_ service: String) -> String {
        "https://tiles.arcgis.com/tiles/ssFJjBXIUyZDrSYZ/arcgis/rest/services/\(service)/MapServer/tile/{z}/{y}/{x}"
    }

    /// Pick the source to stream a chart kind from.
    ///
    /// Manifest sources win over the built-ins so the server can retarget or
    /// correct a service without an app release, and a region-specific source
    /// wins over a global one so European coverage can override the FAA
    /// default where it applies. Sources without streaming are skipped
    /// entirely — they are download-only and have no URL to hand MapKit.
    public static func streamingSource(
        for contentKind: DownloadProduct.ContentKind,
        regionIds: Set<String> = [],
        manifestSources: [ChartSource]
    ) -> ChartSource? {
        let candidates = (manifestSources + faaBuiltIns)
            .filter { $0.contentKind == contentKind && $0.streaming != nil }

        if !regionIds.isEmpty,
           let regional = candidates.first(where: { !$0.regionIds.isEmpty && !regionIds.isDisjoint(with: $0.regionIds) }) {
            return regional
        }
        return candidates.first { $0.regionIds.isEmpty } ?? candidates.first
    }
}
