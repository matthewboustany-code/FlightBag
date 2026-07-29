import Foundation
import Observation
import FBModels

/// An aeronautical chart type the map can display — a *category*, not a
/// source. Which service or file backs a kind is `ChartSource`'s job, carried
/// in the manifest, so a new authority does not need an app release.
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

    /// This kind as a manifest content kind, for matching against
    /// `ChartSource` descriptors.
    var contentKind: DownloadProduct.ContentKind {
        switch self {
        case .vfrSectional: .vfrSectional
        case .ifrLow: .ifrEnrouteLow
        case .ifrHigh: .ifrEnrouteHigh
        }
    }

    /// The manifest's content kind for this chart, when it maps to one the map
    /// can draw. `basemap`/`aeroDatabase`/`plates`/`terrain` are not charts.
    init?(contentKind: DownloadProduct.ContentKind) {
        switch contentKind {
        case .vfrSectional: self = .vfrSectional
        case .ifrEnrouteLow: self = .ifrLow
        case .ifrEnrouteHigh: self = .ifrHigh
        case .basemap, .aeroDatabase, .plates, .terrain: return nil
        }
    }

    /// Classify a downloaded tile set by its file name
    /// ("San_Antonio_sectional.mbtiles" → VFR, "*_ifr_low.mbtiles" → IFR low).
    ///
    /// Fallback only — prefer `ChartStore.kind(for:fileName:)`, which reads
    /// the manifest's answer. This substring match assumes FAA naming: a chart
    /// whose name merely contains "high" would be misclassified as IFR high.
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
    /// Opacity of a plate pinned via `AppEnvironment.activePlateOverlay`.
    var plateOpacity = 0.7
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

    /// Chart sources published by the manifest. Empty until the first
    /// successful fetch, which is why `ChartSource` keeps built-in FAA
    /// descriptors — the map still streams on a cold first launch.
    var chartSources: [ChartSource] = []

    /// Attribution for whatever is on screen, deduplicated.
    ///
    /// Not decoration: the OFMA licence and CC BY-NC both require the source
    /// to be credited, so a chart that renders without this is a chart used
    /// outside its licence.
    var activeChartAttribution: [String] {
        guard let chart else { return [] }
        var credits: [String] = []

        let offline = offlineSetsForSelectedChart
        if offline.isEmpty {
            // Streaming: credit whoever's service is being hit.
            if let source = ChartSource.streamingSource(for: chart.contentKind, manifestSources: chartSources),
               let attribution = source.attribution {
                credits.append(attribution)
            }
        } else {
            // Offline: the authority travels with the file, so the credit
            // survives having never fetched a manifest — which is the normal
            // case in flight, and exactly when the licence still applies.
            credits += offline.compactMap { $0.authority?.attribution }
        }

        var seen = Set<String>()
        return credits.filter { seen.insert($0).inserted }
    }
}
