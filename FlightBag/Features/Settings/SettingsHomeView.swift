import SwiftUI

struct SettingsHomeView: View {
    @AppStorage("hasAcknowledgedDisclaimer") private var hasAcknowledgedDisclaimer = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Flying") {
                    NavigationLink("Aircraft") {
                        AircraftListView()
                    }
                }
                Section("Legal") {
                    Button("Review Advisory-Use Disclaimer") {
                        hasAcknowledgedDisclaimer = false
                    }
                }
                Section("About") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                }
            }
            .navigationTitle("Settings")
        }
    }
}

#Preview {
    SettingsHomeView()
}
