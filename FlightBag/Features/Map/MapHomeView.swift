import SwiftUI
import MapKit

/// The EFB map screen: chart/radar layer stack, ownship, airport tap-through.
struct MapHomeView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var layers = MapLayersState()
    @State private var positionSource = CoreLocationPositionSource()
    @State private var followOwnship = false
    @State private var trackUp = false
    @State private var selectedAirportId: String?
    @State private var showLayersPanel = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            EFBMapView(
                layers: layers,
                position: positionSource.position,
                route: environment.activeMapRoute,
                followOwnship: $followOwnship,
                trackUp: $trackUp,
                onSelectAirport: { selectedAirportId = $0 }
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
            Section("Airports") {
                Toggle("Airport markers", isOn: $layers.airportsEnabled)
            }
        }
        .frame(minWidth: 320, minHeight: 380)
    }
}

#Preview {
    MapHomeView()
        .environment(AppEnvironment())
}
