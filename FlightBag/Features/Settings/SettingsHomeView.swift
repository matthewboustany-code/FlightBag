import SwiftUI

struct SettingsHomeView: View {
    @AppStorage("hasAcknowledgedDisclaimer") private var hasAcknowledgedDisclaimer = false
    @AppStorage("adsbEnabled") private var adsbEnabled = true
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        NavigationStack {
            Form {
                Section("Flying") {
                    NavigationLink("Aircraft") {
                        AircraftListView()
                    }
                }
                adsbSection
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

    private var adsbSection: some View {
        let receiver = environment.gdl90Receiver
        return Section {
            Toggle("Listen for GDL90 (UDP 4000)", isOn: $adsbEnabled)
            LabeledContent("Status") {
                Label(statusText(receiver.state), systemImage: "circle.fill")
                    .foregroundStyle(statusColor(receiver.state))
                    .labelStyle(.titleAndIcon)
                    .font(.callout)
            }
            if receiver.state != .idle {
                LabeledContent("Last heartbeat") {
                    if let heartbeat = receiver.lastHeartbeatAt {
                        Text(heartbeat, style: .relative)
                    } else {
                        Text("—")
                    }
                }
                LabeledContent("Receiver GPS", value: receiver.gpsPositionValid ? "Fix valid" : "No fix")
                LabeledContent("Messages/sec", value: "\(receiver.messagesPerSecond)")
                if !receiver.fisbProductCounts.isEmpty {
                    DisclosureGroup("FIS-B products") {
                        ForEach(receiver.fisbProductCounts.sorted(by: { $0.key < $1.key }), id: \.key) { id, count in
                            LabeledContent(Self.fisbProductName(id), value: "\(count)")
                        }
                    }
                }
            }
        } header: {
            Text("ADS-B Receiver")
        } footer: {
            Text("Connect to your receiver's WiFi network. Receivers that unicast GDL90 (Stratux, Sentry, and similar) work directly.")
        }
    }

    private func statusText(_ state: GDL90Receiver.ConnectionState) -> String {
        switch state {
        case .idle: "Off"
        case .listening: "Listening"
        case .receiving: "Receiving"
        case .stale: "No data"
        case .failed(let message): "Failed: \(message)"
        }
    }

    private func statusColor(_ state: GDL90Receiver.ConnectionState) -> Color {
        switch state {
        case .idle: .secondary
        case .listening: .yellow
        case .receiving: .green
        case .stale: .orange
        case .failed: .red
        }
    }

    static func fisbProductName(_ id: Int) -> String {
        switch id {
        case 8: "NOTAM"
        case 11: "AIRMET"
        case 12: "SIGMET"
        case 13: "SUA"
        case 63: "Regional NEXRAD"
        case 64: "CONUS NEXRAD"
        case 84: "CRL"
        case 103: "Lightning"
        case 413: "Text weather"
        default: "Product \(id)"
        }
    }
}

#Preview {
    SettingsHomeView()
        .environment(AppEnvironment())
}
