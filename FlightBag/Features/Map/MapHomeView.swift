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
            // `-mapDemoRadar YES -mapDemoFollow YES`.
            let defaults = UserDefaults.standard
            if defaults.bool(forKey: "mapDemoRadar") { layers.radarEnabled = true }
            if defaults.bool(forKey: "mapDemoFollow") { followOwnship = true }
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
            if layers.availableCharts.isEmpty {
                Label("No charts downloaded — showing base map", systemImage: "square.stack.3d.up.slash")
            } else if layers.sectionalEnabled {
                Label(layers.availableCharts.map(\.name).joined(separator: ", "), systemImage: "map")
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
            Section("Charts") {
                Toggle("VFR Sectional", isOn: $layers.sectionalEnabled)
                    .disabled(layers.availableCharts.isEmpty)
                if layers.availableCharts.isEmpty {
                    Text("No chart tiles downloaded yet. Chart region downloads arrive with the FlightBag server; sideloaded .mbtiles in the app's Documents folder are picked up automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if layers.sectionalEnabled {
                    LabeledContent("Opacity") {
                        Slider(value: $layers.sectionalOpacity, in: 0.3...1)
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
