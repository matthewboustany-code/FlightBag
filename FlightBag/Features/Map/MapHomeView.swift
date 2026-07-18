import SwiftUI
import MapKit
import FBModels
import FBFlightPlan
import FBGDL90
import FBFISB

/// The EFB map screen: chart/radar layer stack, ownship, airport tap-through.
struct MapHomeView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var layers = MapLayersState()
    @State private var followOwnship = false
    @State private var trackUp = false
    @State private var showLayersPanel = false
    @State private var inspection: MapInspection?
    @State private var showRouteEditor = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            EFBMapView(
                layers: layers,
                position: environment.positionSource.position,
                trafficVersion: environment.trafficStore.membershipVersion,
                fisbRadarVersion: environment.fisbRadarStore.dataVersion,
                route: environment.activeMapRoute,
                procedure: environment.activeProcedure,
                activePlate: environment.activePlateOverlay,
                followOwnship: $followOwnship,
                trackUp: $trackUp,
                onSelectAirport: {
                    showRouteEditor = false
                    inspection = .airport(id: $0)
                },
                onInspectAdvisories: {
                    showRouteEditor = false
                    inspection = .advisories(InspectedAdvisories(advisories: $0))
                }
            )
            .ignoresSafeArea(edges: .bottom)

            VStack(spacing: 10) {
                mapButton(systemImage: "square.3.layers.3d", active: showLayersPanel) {
                    showLayersPanel.toggle()
                }
                .accessibilityIdentifier("map.layers")
                .popover(isPresented: $showLayersPanel, arrowEdge: .top) {
                    LayersPanel(layers: layers)
                        .presentationCompactAdaptation(.popover)
                }

                mapButton(
                    systemImage: followOwnship ? "location.fill" : "location",
                    active: followOwnship
                ) {
                    followOwnship.toggle()
                }
                .accessibilityIdentifier("map.follow")

                mapButton(
                    systemImage: trackUp ? "location.north.line.fill" : "arrow.up.circle",
                    active: trackUp
                ) {
                    trackUp.toggle()
                    if trackUp { followOwnship = true }
                }
                .accessibilityIdentifier("map.trackup")
                .help("Track up / north up")

                if environment.activeMapRoute != nil {
                    mapButton(
                        systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                        active: showRouteEditor
                    ) {
                        showRouteEditor.toggle()
                        if showRouteEditor { inspection = nil }
                    }
                    .accessibilityIdentifier("map.routeEditor")
                    .help("Edit route")
                }
            }
            .padding(.trailing, 12)
            .padding(.top, 8)
        }
        .overlay(alignment: .bottomLeading) {
            // The compact bottom card covers this corner; hide rather than
            // stack.
            if !(inspection != nil && sizeClass == .compact) {
                statusStrip
            }
        }
        .overlay(alignment: sizeClass == .compact ? .bottom : .leading) {
            if let inspection {
                MapInfoPanel(inspection: inspection) { self.inspection = nil }
                    .frame(maxWidth: sizeClass == .compact ? .infinity : 380)
                    .containerRelativeFrame(.vertical) { length, _ in
                        length * (sizeClass == .compact ? 0.42 : 0.82)
                    }
                    .padding(.horizontal, sizeClass == .compact ? 6 : 0)
                    .padding(.leading, sizeClass == .compact ? 0 : 12)
                    .transition(.move(edge: sizeClass == .compact ? .bottom : .leading).combined(with: .opacity))
            } else if showRouteEditor, environment.activeMapRoute != nil {
                RouteEditorPanel { showRouteEditor = false }
                    .frame(maxWidth: sizeClass == .compact ? .infinity : 380)
                    .containerRelativeFrame(.vertical) { length, _ in
                        length * (sizeClass == .compact ? 0.42 : 0.7)
                    }
                    .padding(.horizontal, sizeClass == .compact ? 6 : 0)
                    .padding(.leading, sizeClass == .compact ? 0 : 12)
                    .transition(.move(edge: sizeClass == .compact ? .bottom : .leading).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: inspection)
        .animation(.snappy, value: showRouteEditor)
        .task {
            // Screenshot automation skips the location prompt, which would
            // otherwise sit modally over the map.
            if !UserDefaults.standard.bool(forKey: "mapDemoSkipLocation") {
                environment.positionSource.activate()
            }
            // Launch-argument state for demos/automation, e.g.
            // `-mapDemoRadar YES -mapDemoFollow YES -mapDemoChart ifrlow`.
            let defaults = UserDefaults.standard
            if defaults.bool(forKey: "mapDemoRadar") { layers.radarEnabled = true }
            if let source = defaults.string(forKey: "mapDemoRadarSource"),
               let kind = RadarSource(rawValue: source) {
                layers.radarSource = kind
                layers.radarEnabled = true
            }
            if defaults.bool(forKey: "mapDemoFollow") { followOwnship = true }
            if let chart = defaults.string(forKey: "mapDemoChart") {
                layers.chart = ChartKind(rawValue: chart)
            }
            if defaults.bool(forKey: "mapDemoAdvisories") {
                layers.sigmetsEnabled = true
                layers.airmetSierraEnabled = true
                layers.airmetTangoEnabled = true
                layers.airmetZuluEnabled = true
            }
            let demoAltitude = defaults.double(forKey: "mapDemoAltitudeFilter")
            if demoAltitude > 0 {
                layers.advisoryAltitudeFilterEnabled = true
                layers.advisoryFilterAltitudeFt = demoAltitude
            }
            if defaults.bool(forKey: "mapDemoAero") {
                layers.waypointsEnabled = true
                layers.airwaysLowEnabled = true
                layers.airwaysHighEnabled = true
                layers.enabledAirspaceCategories = Set(Airspace.Category.allCases)
            }
            if defaults.bool(forKey: "mapDemoPanel") { showLayersPanel = true }
            if let inspectId = defaults.string(forKey: "mapDemoInspect") {
                inspection = .airport(id: inspectId)
            }
            if defaults.bool(forKey: "mapDemoInspectAdvisories") {
                inspection = .advisories(InspectedAdvisories(advisories: [
                    AdvisoryDisplayInfo(
                        color: .systemRed,
                        title: "TFR 6/2233",
                        subtitle: "Temporary flight restriction · SFC–3,000 ft",
                        detail: "Demo TFR — stadium event.\nEffective now through 2359Z."
                    ),
                    AdvisoryDisplayInfo(
                        color: .systemOrange,
                        title: "CONVECTIVE SIGMET 4C",
                        subtitle: "Thunderstorms · FL450 and below",
                        detail: "Demo SIGMET — line of storms moving east 25 kt."
                    ),
                ]))
            }
            if defaults.bool(forKey: "adsbDemoSeed") {
                seedDemoTraffic()
                seedDemoRadar()
            }
            // `-mapDemoRoute YES` shows the standard demo route;
            // `-mapDemoRouteEditor YES` also opens the editor panel.
            if defaults.bool(forKey: "mapDemoRoute"),
               let db = environment.aeroDatabase,
               let parsed = try? await RouteParser(resolver: db).parse("KAUS CWK V17 ACT KDAL") {
                environment.activeMapRoute = ActiveMapRoute(label: "KAUS → KDAL", route: parsed)
                if defaults.bool(forKey: "mapDemoRouteEditor") { showRouteEditor = true }
            }
            // `-mapDemoProcedure KAUS:AEROZ2` draws a SID/STAR's branches.
            if let raw = defaults.string(forKey: "mapDemoProcedure"),
               let db = environment.aeroDatabase {
                let parts = raw.split(separator: ":").map(String.init)
                if parts.count == 2,
                   let detail = try? await db.airportDetail(id: parts[0]),
                   let summary = try? await db.procedures(airportId: detail.airport.id, icaoId: detail.airport.icaoId?.rawValue)
                       .first(where: { $0.ident == parts[1] }),
                   let legs = try? await db.procedureLegs(airportId: detail.airport.id, icaoId: detail.airport.icaoId?.rawValue, ident: summary.ident) {
                    environment.activeProcedure = ActiveMapProcedure(
                        airportDisplayId: detail.airport.displayIdentifier,
                        ident: summary.ident,
                        kind: summary.kind,
                        legs: legs
                    )
                }
            }
            // `-mapDemoPlate KAUS` pins the airport's first approach plate
            // (downloads it if needed — the simulator has internet);
            // `-mapDemoPlateKind apd` picks the airport diagram instead;
            // `-mapDemoPlateChart "RNAV (GPS) Z RWY 28"` narrows by chart
            // name substring.
            if let plateAirport = defaults.string(forKey: "mapDemoPlate"),
               let db = environment.aeroDatabase,
               let detail = try? await db.airportDetail(id: plateAirport) {
                let kind: PlateMetadata.Category =
                    defaults.string(forKey: "mapDemoPlateKind") == "apd" ? .airportDiagram : .approach
                let chartFilter = defaults.string(forKey: "mapDemoPlateChart")?.uppercased()
                if let plate = detail.plates.first(where: { plate in
                    plate.category == kind
                        && (chartFilter.map { plate.chartName.uppercased().contains($0) } ?? true)
                }) {
                    environment.activePlateOverlay = plate
                }
            }
            if layers.anyAdvisoryEnabled {
                await environment.advisoryStore.refreshIfStale()
            }
        }
        // Re-scan on first appearance and whenever a download installs or
        // deletes chart tiles, so the map switches to offline immediately.
        .task(id: environment.downloadCenter.chartsVersion) {
            layers.availableCharts = environment.chartStore.availableCharts()
            layers.availableBasemaps = environment.chartStore.availableBasemaps()
        }
    }

    private var radarStatusText: String {
        switch layers.radarSource {
        case .internet:
            return "NEXRAD via IEM"
        case .adsb:
            guard let updated = environment.fisbRadarStore.updatedAt else {
                return "NEXRAD via ADS-B · waiting"
            }
            let age = Int(Date().timeIntervalSince(updated) / 60)
            return "NEXRAD via ADS-B · \(age) min old"
        }
    }

    /// Deterministic traffic around the map center for screenshots
    /// (`-adsbDemoSeed YES`), no receiver required.
    private func seedDemoTraffic() {
        let center = CLLocationCoordinate2D(latitude: 30.1945, longitude: -97.6699)
        let samples: [(String, Double, Double, Int, Double, Int?, Bool)] = [
            ("N771TC", 0.06, 0.05, 4500, 210, 600, true),
            ("SWA1442", -0.05, 0.08, 8500, 90, -700, true),
            ("N9021H", 0.09, -0.04, 3200, 315, 0, true),
            ("N556DG", -0.07, -0.06, 5500, 45, 500, true),
            ("N700GT", 0.005, 0.004, 600, 270, 0, false),
        ]
        for (index, sample) in samples.enumerated() {
            let report = GDL90Message.TrafficReport(
                address: 0xC0_00_01 + UInt32(index),
                latitude: center.latitude + sample.1,
                longitude: center.longitude + sample.2,
                altitudeFeet: sample.3,
                airborne: sample.6,
                trackDegrees: sample.4,
                groundSpeedKt: 120,
                verticalVelocityFpm: sample.5,
                callsign: sample.0
            )
            environment.trafficStore.ingest(report: report)
        }
    }

    /// A synthetic storm cell near the map center for screenshots.
    /// Intensity falls off with real distance from the core, so the cell
    /// stays contiguous across block boundaries.
    private func seedDemoRadar() {
        let core = (latitude: 30.35, longitude: -97.4)
        let radiusDegrees = 0.35
        // Blocks are 48' wide but only 4' tall, so a round cell spans two
        // columns and a dozen rows (row stride is 450 blocks).
        var blocks: [NEXRADBlock] = []
        for row in 449...461 {
            for column in 327...328 {
                let blockNumber = row * 450 + column
                var bins = [UInt8](repeating: 0, count: NEXRADGlobalBlock.binsPerBlock)
                var painted = false
                for index in bins.indices {
                    guard let bin = NEXRADBlockGeometry.binBounds(
                        blockNumber: blockNumber, scaleFactor: 0, binIndex: index
                    ) else { continue }
                    let dy = (bin.south + bin.north) / 2 - core.latitude
                    let dx = ((bin.west + bin.east) / 2 - core.longitude) * 0.86  // cos(30°)
                    let distance = (dx * dx + dy * dy).squareRoot()
                    guard distance < radiusDegrees else { continue }
                    bins[index] = UInt8(max(0, min(7, Int((7.0 * (1 - distance / radiusDegrees)).rounded()))))
                    painted = true
                }
                if painted {
                    blocks.append(NEXRADBlock(blockNumber: blockNumber, scaleFactor: 0, intensities: bins))
                }
            }
        }
        environment.fisbRadarStore.ingest(NEXRADProduct(scope: .regional, blocks: blocks))
    }

    private var statusStrip: some View {
        HStack(spacing: 8) {
            if let chart = layers.chart {
                let offline = layers.offlineSetsForSelectedChart
                Label(
                    offline.isEmpty
                        ? "\(chart.displayName) · FAA streaming"
                        : "\(chart.displayName) · offline (\(offline.map(\.name).joined(separator: ", ")))",
                    systemImage: offline.isEmpty ? "antenna.radiowaves.left.and.right" : "internaldrive"
                )
            }
            if layers.radarEnabled {
                Label(radarStatusText, systemImage: "cloud.rain")
            }
            if let route = environment.activeMapRoute {
                Button {
                    environment.activeMapRoute = nil
                } label: {
                    Label(route.label, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.pink)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("map.clearRoute")
            }
            if let plate = environment.activePlateOverlay {
                Button {
                    environment.activePlateOverlay = nil
                } label: {
                    Label(plate.chartName, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.teal)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("map.clearPlate")
            }
            if let procedure = environment.activeProcedure {
                Button {
                    environment.activeProcedure = nil
                } label: {
                    Label(procedure.label, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("map.clearProcedure")
            }
            if let position = environment.positionSource.position {
                Label(position.sourceName, systemImage: position.sourceName == "ADS-B"
                    ? "antenna.radiowaves.left.and.right" : "location.fill")
                    .foregroundStyle(position.sourceName == "ADS-B" ? .green : .secondary)
                    .accessibilityIdentifier("map.positionSource")
            }
            if environment.positionSource.isDenied {
                Label("Location off", systemImage: "location.slash")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption2)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.thinMaterial, in: Capsule())
        .padding(.leading, 12)
        .padding(.bottom, 10)
    }

    private func mapButton(systemImage: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 40, height: 40)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(active ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

/// Layer toggles + opacity. Traffic and FIS-B join this panel in Phase 4.
private struct LayersPanel: View {
    @Bindable var layers: MapLayersState
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        Form {
            Section("Aeronautical Chart") {
                Picker("Chart", selection: $layers.chart) {
                    Text("None").tag(ChartKind?.none)
                    ForEach(ChartKind.allCases) { kind in
                        Text(kind.displayName).tag(Optional(kind))
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("layers.chart")
                if let chart = layers.chart {
                    LabeledContent("Opacity") {
                        Slider(value: $layers.chartOpacity, in: 0.3...1)
                    }
                    if layers.offlineSetsForSelectedChart.isEmpty {
                        Text("Streaming from FAA chart services — requires internet and is not for offline use. Downloaded regions (or .mbtiles sideloaded via the Files app) are used automatically.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Using downloaded tiles: \(layers.offlineSetsForSelectedChart.map(\.name).joined(separator: ", ")). Areas outside them are blank — streaming fills in once they're removed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if !layers.availableBasemaps.isEmpty {
                    Toggle("Offline basemap", isOn: $layers.basemapEnabled)
                        .accessibilityIdentifier("layers.basemap")
                }
            }
            if let plate = environment.activePlateOverlay {
                Section("Approach Plate") {
                    LabeledContent("Chart") {
                        Text(plate.chartName)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Opacity") {
                        Slider(value: $layers.plateOpacity, in: 0.2...1)
                            .accessibilityIdentifier("layers.plateOpacity")
                    }
                    Button("Remove from Map", role: .destructive) {
                        environment.activePlateOverlay = nil
                    }
                    .accessibilityIdentifier("layers.removePlate")
                }
            }
            Section {
                Toggle(isOn: $layers.trafficEnabled) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrowtriangle.up.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                        Text("ADS-B Traffic")
                    }
                }
                .accessibilityIdentifier("layers.traffic")
            } header: {
                Text("Traffic")
            } footer: {
                Text("Targets from your ADS-B receiver. Traffic is advisory only and may be incomplete — see and avoid.")
                    .font(.caption)
            }
            Section("Weather") {
                Toggle("Radar (NEXRAD)", isOn: $layers.radarEnabled)
                if layers.radarEnabled {
                    Picker("Source", selection: $layers.radarSource) {
                        ForEach(RadarSource.allCases) { source in
                            Text(source.displayName).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("layers.radarSource")
                    LabeledContent("Opacity") {
                        Slider(value: $layers.radarOpacity, in: 0.2...1)
                    }
                    Text(layers.radarSource == .adsb
                        ? "FIS-B radar comes from your ADS-B receiver and works with no internet. It is several minutes old. Never use it to penetrate weather."
                        : "Internet radar is delayed several minutes and needs a connection. Never use it to penetrate weather.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Section {
                Toggle("Airports", isOn: $layers.airportsEnabled)
                Toggle("Waypoints (navaids & fixes)", isOn: $layers.waypointsEnabled)
                Toggle("Airways — Victor/T (low)", isOn: $layers.airwaysLowEnabled)
                Toggle("Airways — Jet/Q (high)", isOn: $layers.airwaysHighEnabled)
                ForEach(Airspace.Category.allCases, id: \.self) { category in
                    Toggle(isOn: airspaceBinding(category)) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color(category.strokeColor))
                                .frame(width: 10, height: 10)
                            Text("\(category.displayName) airspace")
                        }
                    }
                }
            } header: {
                Text("Aeronautical")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Waypoints and airways come from the offline database; airspace boundaries stream from FAA services per view. Zoom in to reveal fixes.")
                    if let error = environment.airspaceStore.lastError {
                        Text(error).foregroundStyle(.orange)
                    }
                }
                .font(.caption)
            }

            Section {
                advisoryToggle("TFRs", isOn: $layers.tfrsEnabled, category: .tfr, count: AdvisoryOverlayBuilder.visibleTFRAreas(layers: layers, store: store).count)
                advisoryToggle("SIGMETs", isOn: $layers.sigmetsEnabled, category: .sigmet, count: AdvisoryOverlayBuilder.visibleSigmets(layers: layers, store: store).count)
                advisoryToggle("AIRMET Sierra (IFR/Mtn)", isOn: $layers.airmetSierraEnabled, category: .airmetSierra, count: airmetCount(.sierra))
                advisoryToggle("AIRMET Tango (Turb/Wind)", isOn: $layers.airmetTangoEnabled, category: .airmetTango, count: airmetCount(.tango))
                advisoryToggle("AIRMET Zulu (Icing)", isOn: $layers.airmetZuluEnabled, category: .airmetZulu, count: airmetCount(.zulu))

                Toggle("Filter by altitude", isOn: $layers.advisoryAltitudeFilterEnabled)
                    .accessibilityIdentifier("layers.altitudeFilter")
                if layers.advisoryAltitudeFilterEnabled {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("At \(Int(layers.advisoryFilterAltitudeFt).formatted()) ft MSL")
                            .font(.callout.monospacedDigit())
                        Slider(value: $layers.advisoryFilterAltitudeFt, in: 0...45000, step: 500)
                    }
                }
            } header: {
                Text("Airspace & Advisories")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if layers.advisoryAltitudeFilterEnabled {
                        Text("Showing advisories whose altitude band includes \(Int(layers.advisoryFilterAltitudeFt).formatted()) ft. Advisories without published altitudes always show.")
                    }
                    if let refreshed = store.lastRefresh {
                        Text("Refreshed \(refreshed.formatted(date: .omitted, time: .shortened)). Tap an outlined area on the map for details.")
                    }
                    if let error = store.lastError {
                        Text(error).foregroundStyle(.orange)
                    }
                    Text("Advisories require internet and can lag official sources. Always brief through Flight Service.")
                        .foregroundStyle(.orange)
                }
                .font(.caption)
            }

        }
        .frame(minWidth: 340, minHeight: 640)
        .task(id: layers.anyAdvisoryEnabled) {
            if layers.anyAdvisoryEnabled {
                await store.refreshIfStale()
            }
        }
    }

    private var store: AdvisoryStore { environment.advisoryStore }

    private func airspaceBinding(_ category: Airspace.Category) -> Binding<Bool> {
        Binding(
            get: { layers.enabledAirspaceCategories.contains(category) },
            set: { enabled in
                if enabled {
                    layers.enabledAirspaceCategories.insert(category)
                } else {
                    layers.enabledAirspaceCategories.remove(category)
                }
            }
        )
    }

    private func airmetCount(_ product: GraphicalAirmet.Product) -> Int {
        AdvisoryOverlayBuilder.visibleAirmets(product, layers: layers, store: store).count
    }

    private func advisoryToggle(_ title: String, isOn: Binding<Bool>, category: AdvisoryCategory, count: Int) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(category.strokeColor))
                    .frame(width: 10, height: 10)
                Text(title)
                if isOn.wrappedValue, count > 0 {
                    Text("\(count)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(category.strokeColor).opacity(0.2), in: Capsule())
                }
            }
        }
    }
}

/// Identifiable wrapper for a batch of tapped advisories.
struct InspectedAdvisories: Identifiable {
    let id = UUID()
    var advisories: [AdvisoryDisplayInfo]
}

#Preview {
    MapHomeView()
        .environment(AppEnvironment())
}
