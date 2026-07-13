import SwiftUI

/// Top-level navigation: sidebar on iPad, tab bar on iPhone.
struct RootTabView: View {
    @AppStorage("hasAcknowledgedDisclaimer") private var hasAcknowledgedDisclaimer = false

    var body: some View {
        TabView {
            Tab("Airports", systemImage: "airplane.arrival") {
                AirportsHomeView()
            }
            Tab("Map", systemImage: "map") {
                MapHomeView()
            }
            Tab("Flights", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                FlightsHomeView()
            }
            Tab("Downloads", systemImage: "arrow.down.circle") {
                DownloadsHomeView()
            }
            Tab("Settings", systemImage: "gearshape") {
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
