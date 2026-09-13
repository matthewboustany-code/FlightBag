import Foundation
import Observation
import FBModels

/// An aeronautical chart type the map can display — a *category*, not a
/// source. Which service or file backs a kind is `ChartSource`'s job, carried
/// in the manifest, so a new authority does not need an app release.
nonisolated enum ChartKind: String, CaseIterable, Identifiable, Sendable, Codable {
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

nonisolated enum RadarSource: String, CaseIterable, Identifiable, Sendable, Codable {
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
    /// Off by default: NOTAM circles cluster tightly around a busy field and
    /// would bury the chart the moment a route is loaded.
    var notamsEnabled = false

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
        tfrsEnabled || sigmetsEnabled || airmetSierraEnabled || airmetTangoEnabled
            || airmetZuluEnabled || notamsEnabled
    }

    /// Downloaded tile sets found on disk; refreshed when the map appears.
    var availableCharts: [ChartStore.ChartSet] = []

    /// Downloaded offline basemaps, drawn under everything else. On by
    /// default — the layer only exists once the user downloads it.
    var basemapEnabled = true
    var availableBasemaps: [ChartStore.ChartSet] = []

    /// Downloaded tile sets backing the selected chart kind. They render over
    /// the streaming layer rather than instead of it.
    var offlineSetsForSelectedChart: [ChartStore.ChartSet] {
        guard let chart else { return [] }
        return availableCharts.filter { $0.kind == chart }
    }

    /// Stream chart tiles for everything the downloaded sets don't cover.
    /// On by default — the alternative is a blank map one state over — but
    /// a pilot metering cellular data can turn it off and fly on what is
    /// genuinely on the device.
    var streamChartGaps = true

    /// Chart sources published by the manifest. Empty until the first
    /// successful fetch, which is why `ChartSource` keeps built-in FAA
    /// descriptors — the map still streams on a cold first launch.
    var chartSources: [ChartSource] = []

    /// Who the selected chart streams from ("FAA", "open flightmaps"), or nil
    /// when nothing streams it — the status strip must not claim a service
    /// that isn't being used.
    var streamingAuthorityName: String? {
        guard let chart else { return nil }
        return ChartSource.streamingSource(for: chart.contentKind, manifestSources: chartSources)?
            .authority.displayName
    }

    /// Attribution for whatever is on screen, deduplicated.
    ///
    /// Not decoration: the OFMA licence and CC BY-NC both require the source
    /// to be credited, so a chart that renders without this is a chart used
    /// outside its licence.
    var activeChartAttribution: [String] {
        guard let chart else { return [] }
        var credits: [String] = []

        let offline = offlineSetsForSelectedChart
        // Offline: the authority travels with the file, so the credit
        // survives having never fetched a manifest — which is the normal
        // case in flight, and exactly when the licence still applies.
        credits += offline.compactMap { $0.authority?.attribution }
        if offline.isEmpty || streamChartGaps {
            // Streaming: credit whoever's service is being hit. Both layers
            // can be on screen at once, so both get credited.
            if let source = ChartSource.streamingSource(for: chart.contentKind, manifestSources: chartSources),
               let attribution = source.attribution {
                credits.append(attribution)
            }
        }

        var seen = Set<String>()
        return credits.filter { seen.insert($0).inserted }
    }
}

// MARK: - Persistence

extension MapLayersState {
    static let defaultsKey = "mapLayers"

    /// The user-set fields, as saved between launches. Deliberately excludes
    /// what is discovered at runtime (available charts, basemaps, manifest
    /// sources). Every field is optional so a snapshot from an older build,
    /// missing whatever was added since, still loads.
    struct Snapshot: Codable, Equatable {
        /// A `ChartKind` raw value, or "none" for the base map alone. Not
        /// `ChartKind??`: JSON can't tell "no chart" from "not saved".
        var chart: String?
        var chartOpacity: Double?
        var plateOpacity: Double?
        var radarEnabled: Bool?
        var radarOpacity: Double?
        var radarSource: RadarSource?
        var airportsEnabled: Bool?
        var trafficEnabled: Bool?
        var waypointsEnabled: Bool?
        var airwaysLowEnabled: Bool?
        var airwaysHighEnabled: Bool?
        var enabledAirspaceCategories: Set<Airspace.Category>?
        var tfrsEnabled: Bool?
        var sigmetsEnabled: Bool?
        var airmetSierraEnabled: Bool?
        var airmetTangoEnabled: Bool?
        var airmetZuluEnabled: Bool?
        var notamsEnabled: Bool?
        var advisoryAltitudeFilterEnabled: Bool?
        var advisoryFilterAltitudeFt: Double?
        var basemapEnabled: Bool?
        var streamChartGaps: Bool?
    }

    var snapshot: Snapshot {
        Snapshot(
            chart: chart?.rawValue ?? "none", chartOpacity: chartOpacity, plateOpacity: plateOpacity,
            radarEnabled: radarEnabled, radarOpacity: radarOpacity, radarSource: radarSource,
            airportsEnabled: airportsEnabled, trafficEnabled: trafficEnabled,
            waypointsEnabled: waypointsEnabled, airwaysLowEnabled: airwaysLowEnabled,
            airwaysHighEnabled: airwaysHighEnabled, enabledAirspaceCategories: enabledAirspaceCategories,
            tfrsEnabled: tfrsEnabled, sigmetsEnabled: sigmetsEnabled, airmetSierraEnabled: airmetSierraEnabled,
            airmetTangoEnabled: airmetTangoEnabled, airmetZuluEnabled: airmetZuluEnabled,
            notamsEnabled: notamsEnabled, advisoryAltitudeFilterEnabled: advisoryAltitudeFilterEnabled,
            advisoryFilterAltitudeFt: advisoryFilterAltitudeFt, basemapEnabled: basemapEnabled,
            streamChartGaps: streamChartGaps
        )
    }

    func apply(_ snapshot: Snapshot) {
        if let raw = snapshot.chart { chart = ChartKind(rawValue: raw) }
        chartOpacity = snapshot.chartOpacity ?? chartOpacity
        plateOpacity = snapshot.plateOpacity ?? plateOpacity
        radarEnabled = snapshot.radarEnabled ?? radarEnabled
        radarOpacity = snapshot.radarOpacity ?? radarOpacity
        radarSource = snapshot.radarSource ?? radarSource
        airportsEnabled = snapshot.airportsEnabled ?? airportsEnabled
        trafficEnabled = snapshot.trafficEnabled ?? trafficEnabled
        waypointsEnabled = snapshot.waypointsEnabled ?? waypointsEnabled
        airwaysLowEnabled = snapshot.airwaysLowEnabled ?? airwaysLowEnabled
        airwaysHighEnabled = snapshot.airwaysHighEnabled ?? airwaysHighEnabled
        enabledAirspaceCategories = snapshot.enabledAirspaceCategories ?? enabledAirspaceCategories
        tfrsEnabled = snapshot.tfrsEnabled ?? tfrsEnabled
        sigmetsEnabled = snapshot.sigmetsEnabled ?? sigmetsEnabled
        airmetSierraEnabled = snapshot.airmetSierraEnabled ?? airmetSierraEnabled
        airmetTangoEnabled = snapshot.airmetTangoEnabled ?? airmetTangoEnabled
        airmetZuluEnabled = snapshot.airmetZuluEnabled ?? airmetZuluEnabled
        notamsEnabled = snapshot.notamsEnabled ?? notamsEnabled
        advisoryAltitudeFilterEnabled = snapshot.advisoryAltitudeFilterEnabled ?? advisoryAltitudeFilterEnabled
        advisoryFilterAltitudeFt = snapshot.advisoryFilterAltitudeFt ?? advisoryFilterAltitudeFt
        basemapEnabled = snapshot.basemapEnabled ?? basemapEnabled
        streamChartGaps = snapshot.streamChartGaps ?? streamChartGaps
    }

    /// Restores the last saved layer state, if any.
    func load(from defaults: UserDefaults = .standard) {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        apply(snapshot)
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    static let followDefaultsKey = "mapFollowOwnship"
    static let trackUpDefaultsKey = "mapTrackUp"

    /// True when screenshot automation is driving the map. Its launch
    /// arguments set layers for one run and must not become the saved state.
    static var isDemoLaunch: Bool {
        ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("-mapDemo") }
    }
}
