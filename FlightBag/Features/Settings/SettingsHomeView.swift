import SwiftUI
import FBModels

struct SettingsHomeView: View {
    @AppStorage("hasAcknowledgedDisclaimer") private var hasAcknowledgedDisclaimer = false
    @AppStorage("adsbEnabled") private var adsbEnabled = true
    @AppStorage(ServerConfig.defaultsKey) private var serverBaseURL = ""
    @AppStorage(UnitSystemPreference.defaultsKey) private var unitSystem = UnitSystemPreference.automatic.rawValue
    @AppStorage("openAIPKey") private var openAIPKey = ""
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        NavigationStack {
            Form {
                Section("Flying") {
                    NavigationLink("Aircraft") {
                        AircraftListView()
                    }
                }
                unitsSection
                adsbSection
                Section {
                    TextField("http://192.168.1.50:8080", text: $serverBaseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("settings.serverURL")
                } header: {
                    Text("Download Server")
                } footer: {
                    // The old placeholder showed https://, which sends people
                    // straight into a TLS handshake against a server that only
                    // speaks plain HTTP — the failure looks like the server is
                    // down rather than like a typo.
                    Text("Where chart-region downloads come from. Include the scheme: a server on your own network is usually http://, not https://. Leave empty until a FlightBag data server is available.")
                }
                Section {
                    SecureField("openAIP API key", text: $openAIPKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("settings.openAIPKey")
                } header: {
                    Text("Worldwide Airspace")
                } footer: {
                    Text("Airspace outside the US comes from openAIP, which needs a free key from your openAIP profile. "
                        + "Their data is licensed for non-commercial use and requires attribution. "
                        + "Without a key, airspace is shown for US airspace only.")
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

    private var unitsSection: some View {
        let selected = UnitSystemPreference(rawValue: unitSystem) ?? .automatic
        return Section {
            Picker("Units", selection: $unitSystem) {
                ForEach(UnitSystemPreference.allCases) { preference in
                    Text(preference.displayName).tag(preference.rawValue)
                }
            }
            .accessibilityIdentifier("settings.units")
        } header: {
            Text("Units")
        } footer: {
            if let detail = selected.detail {
                Text(detail)
            } else {
                // Naming the sample values makes the choice concrete without
                // the pilot having to leave Settings to check.
                Text("Altimeter \(selected.preferences(for: .unknown).formatAltimeter(hPa: 1013.25)), "
                    + "visibility \(selected.preferences(for: .unknown).formatVisibility(statuteMiles: 10)).")
            }
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
