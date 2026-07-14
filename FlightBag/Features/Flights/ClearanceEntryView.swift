import SwiftUI
import SwiftData

/// IFR clearance recording in CRAFT order — the copy sequence every
/// instrument pilot writes: Clearance limit, Route, Altitude, Frequency,
/// Transponder.
struct ClearanceEntryView: View {
    @Bindable var clearance: ClearanceRecord

    var body: some View {
        Form {
            Section {
                craftField("C", "Clearance limit", "KDAL", $clearance.clearanceLimit)
                craftField("R", "Route", "RV CWK V17 ACT", $clearance.route)
                craftField("A", "Altitude", "3000, expect 7000 in 10", $clearance.altitude)
                craftField("F", "Frequency", "125.32", $clearance.frequency)
                craftField("T", "Transponder", "4521", $clearance.transponder)
            } header: {
                Text("CRAFT")
            } footer: {
                Text("Received \(clearance.receivedAt, format: .dateTime.month().day().hour().minute())")
            }

            Section("Notes") {
                TextField("Hold for release, void time…", text: $clearance.freeText, axis: .vertical)
                    .lineLimit(2...5)
            }
        }
        .navigationTitle("Clearance")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func craftField(_ letter: String, _ label: String, _ prompt: String, _ text: Binding<String>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(letter)
                .font(.title3.bold().monospaced())
                .foregroundStyle(.tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                TextField(prompt, text: text, axis: .vertical)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("clearance.\(letter)")
            }
        }
    }
}

#Preview {
    NavigationStack {
        ClearanceEntryView(clearance: ClearanceRecord())
    }
    .modelContainer(for: Flight.self, inMemory: true)
}
