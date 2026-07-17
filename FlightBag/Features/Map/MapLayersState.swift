import Foundation
import Observation
import FBModels

/// An aeronautical chart type the map can display. Each kind renders from
/// downloaded MBTiles when available, otherwise it streams from the FAA's
/// public ArcGIS raster tile services (aeronautical data is public domain).
enum ChartKind: String, CaseIterable, Identifiable, Sendable {
    case vfrSectional = "vfr"
    case ifrLow = "ifrlow"
    case ifrHigh = "ifrhigh"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .vfrSectional: "VFR Sectional"
        case .ifrLow: "IFR Enroute Low"
        case .ifrHigh: "IFR Enroute High"
        }
    }

    /// FAA AIS tile service backing this chart when no offline tiles exist.
    private var faaServiceName: String {
        switch self {
        case .vfrSectional: "VFR_Sectional"
        case .ifrLow: "IFR_AreaLow"
        case .ifrHigh: "IFR_High"
        }
    }

    var streamingURLTemplate: String {
        "https://tiles.arcgis.com/tiles/ssFJjBXIUyZDrSYZ/arcgis/rest/services/\(faaServiceName)/MapServer/tile/{z}/{y}/{x}"
    }

    /// Zoom levels the FAA service publishes; outside this range the layer
    /// draws nothing (MapKit does not resample raster tiles).
    var streamingZoomRange: ClosedRange<Int> {
        switch self {
        case .vfrSectional: 8...12
        case .ifrLow: 7...12
        case .ifrHigh: 5...9
        }
    }

    /// Classify a downloaded tile set by its file name
    /// ("San_Antonio_sectional.mbtiles" → VFR, "*_ifr_low.mbtiles" → IFR low).
    static func kind(forFileName file: String) -> ChartKind {
        let lower = file.lowercased()
        if lower.contains("ifr_high") || lower.contains("ifrhigh") || lower.contains("high") { return .ifrHigh }
        if lower.contains("ifr") { return .ifrLow }
        return .vfrSectional
    }
}

enum RadarSource: String, CaseIterable, Identifiable, Sendable {
    case internet
    case adsb

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .internet: "Internet"
        case .adsb: "ADS-B"
        }
    }
}

/// User-controlled layer stack for the EFB map. Layers are data, not code.
@Observable
final class MapLayersState {
    /// The selected aeronautical chart; nil shows the base map only.
    var chart: ChartKind? = .vfrSectional
    var chartOpacity = 1.0
    var radarEnabled = false
    var radarOpacity = 0.7
    /// Where radar comes from: the internet mosaic or the ADS-B receiver's
    /// FIS-B uplink (the only source that works airborne, offline).
    var radarSource: RadarSource = .internet
    var airportsEnabled = true
    /// ADS-B traffic targets from the receiver.
    var trafficEnabled = true

    // Aeronautical vector layer, drawn over the chart from the offline
    // database (waypoints, airways) and FAA airspace services.
    var waypointsEnabled = false
    var airwaysLowEnabled = false
    var airwaysHighEnabled = false
    var enabledAirspaceCategories: Set<Airspace.Category> = []

    var anyAeronauticalEnabled: Bool {
        waypointsEnabled || airwaysLowEnabled || airwaysHighEnabled || !enabledAirspaceCategories.isEmpty
    }

    // Advisory overlays. TFRs default on: busting one is a certificate
    // action, so they surface unless the pilot opts out.
    var tfrsEnabled = true
    var sigmetsEnabled = false
    var airmetSierraEnabled = false
    var airmetTangoEnabled = false
    var airmetZuluEnabled = false

    /// When enabled, only advisories whose altitude band includes the planned
    /// altitude are drawn; advisories without published altitudes always show.
    var advisoryAltitudeFilterEnabled = false
    var advisoryFilterAltitudeFt: Double = 6500

    /// True when the advisory's vertical extent matters at the filter
    /// altitude (or the filter is off).
    func passesAltitudeFilter(_ band: AltitudeBand) -> Bool {
        guard advisoryAltitudeFilterEnabled else { return true }
        return band.contains(altitudeFt: Int(advisoryFilterAltitudeFt))
    }

    var anyAdvisoryEnabled: Bool {
        tfrsEnabled || sigmetsEnabled || airmetSierraEnabled || airmetTangoEnabled || airmetZuluEnabled
    }

    /// Downloaded tile sets found on disk; refreshed when the map appears.
    var availableCharts: [ChartStore.ChartSet] = []

    /// Downloaded offline basemaps, drawn under everything else. On by
    /// default — the layer only exists once the user downloads it.
    var basemapEnabled = true
    var availableBasemaps: [ChartStore.ChartSet] = []

    /// Downloaded tile sets backing the selected chart kind (offline wins
    /// over streaming).
    var offlineSetsForSelectedChart: [ChartStore.ChartSet] {
        guard let chart else { return [] }
        return availableCharts.filter { $0.kind == chart }
    }
}
