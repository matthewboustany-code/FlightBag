import SwiftUI
import MapKit
import FBModels

/// The EFB map screen: chart/radar layer stack, ownship, airport tap-through.
struct MapHomeView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var layers = MapLayersState()
    @State private var positionSource = CoreLocationPositionSource()
    @State private var followOwnship = false
    @State private var trackUp = false
    @State private var selectedAirportId: String?
    @State private var showLayersPanel = false
    @State private var inspectedAdvisories: InspectedAdvisories?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            EFBMapView(
                layers: layers,
                position: positionSource.position,
                route: environment.activeMapRoute,
                followOwnship: $followOwnship,
                trackUp: $trackUp,
                onSelectAirport: { selectedAirportId = $0 },
                onInspectAdvisories: { inspectedAdvisories = InspectedAdvisories(advisories: $0) }
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
            }
            .padding(.trailing, 12)
            .padding(.top, 8)
        }
        .overlay(alignment: .bottomLeading) {
            statusStrip
        }
        .task {
            positionSource.activate()
            layers.availableCharts = ChartStore().availableCharts()
            // Launch-argument state for demos/automation, e.g.
            // `-mapDemoRadar YES -mapDemoFollow YES -mapDemoChart ifrlow`.
            let defaults = UserDefaults.standard
            if defaults.bool(forKey: "mapDemoRadar") { layers.radarEnabled = true }
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
            if layers.anyAdvisoryEnabled {
                await environment.advisoryStore.refreshIfStale()
            }
        }
        .sheet(item: $inspectedAdvisories) { inspected in
            AdvisoryInspectorSheet(advisories: inspected.advisories)
        }
        .sheet(item: $selectedAirportId) { airportId in
            NavigationStack {
                AirportDetailView(airportId: airportId)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { selectedAirportId = nil }
                        }
                    }
            }
        }
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
                Label("NEXRAD via IEM", systemImage: "cloud.rain")
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
            if positionSource.isDenied {
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

extension String: @retroactive Identifiable {
    public var id: String { self }
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
            }
            Section("Weather") {
                Toggle("Radar (NEXRAD)", isOn: $layers.radarEnabled)
                if layers.radarEnabled {
                    LabeledContent("Opacity") {
                        Slider(value: $layers.radarOpacity, in: 0.2...1)
                    }
                    Text("Internet radar is delayed several minutes. Never use it to penetrate weather.")
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

/// Identifiable wrapper so tapped advisories drive a sheet.
struct InspectedAdvisories: Identifiable {
    let id = UUID()
    var advisories: [AdvisoryDisplayInfo]
}

/// Details for advisories under a map tap.
private struct AdvisoryInspectorSheet: View {
    let advisories: [AdvisoryDisplayInfo]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(advisories) { advisory in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color(advisory.color))
                            .frame(width: 10, height: 10)
                        Text(advisory.title)
                            .font(.headline)
                    }
                    if !advisory.subtitle.isEmpty {
                        Text(advisory.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if !advisory.detail.isEmpty {
                        Text(advisory.detail)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 4)
            }
            .navigationTitle(advisories.count == 1 ? "Advisory" : "\(advisories.count) Advisories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

#Preview {
    MapHomeView()
        .environment(AppEnvironment())
}
