import SwiftUI

enum AppTab: String {
    case airports, map, flights, downloads, settings
}

/// Top-level navigation: sidebar on iPad, tab bar on iPhone.
struct RootTabView: View {
    @AppStorage("hasAcknowledgedDisclaimer") private var hasAcknowledgedDisclaimer = false
    // Launch-selectable (e.g. `-initialTab map`) for deep links and demos.
    @State private var selectedTab: AppTab =
        AppTab(rawValue: UserDefaults.standard.string(forKey: "initialTab") ?? "") ?? .airports

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Airports", systemImage: "airplane.arrival", value: .airports) {
                AirportsHomeView()
            }
            Tab("Map", systemImage: "map", value: .map) {
                MapHomeView()
            }
            Tab("Flights", systemImage: "point.topleft.down.to.point.bottomright.curvepath", value: .flights) {
                FlightsHomeView()
            }
            Tab("Downloads", systemImage: "arrow.down.circle", value: .downloads) {
                DownloadsHomeView()
            }
            Tab("Settings", systemImage: "gearshape", value: .settings) {
                SettingsHomeView()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .sheet(isPresented: .constant(!hasAcknowledgedDisclaimer)) {
            DisclaimerView {
                hasAcknowledgedDisclaimer = true
            }
            .interactiveDismissDisabled()
        }
    }
}

#Preview {
    RootTabView()
        .environment(AppEnvironment())
}
