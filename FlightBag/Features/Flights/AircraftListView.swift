import SwiftUI
import SwiftData

/// Aircraft profiles: performance and equipment defaults that seed the ICAO
/// plan form.
struct AircraftListView: View {
    @Query(sort: \AircraftProfile.tailNumber) private var aircraft: [AircraftProfile]
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        List {
            ForEach(aircraft) { profile in
                NavigationLink {
                    AircraftEditorView(aircraft: profile)
                } label: {
                    VStack(alignment: .leading) {
                        Text(profile.tailNumber.isEmpty ? "New Aircraft" : profile.tailNumber)
                            .font(.headline.monospaced())
                        Text(subtitle(for: profile))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { offsets in
                for offset in offsets {
                    modelContext.delete(aircraft[offset])
                }
            }
        }
        .overlay {
            if aircraft.isEmpty {
                ContentUnavailableView(
                    "No Aircraft",
                    systemImage: "airplane",
                    description: Text("Add your aircraft's equipment and performance once; every flight plan autofills from it.")
                )
            }
        }
        .navigationTitle("Aircraft")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add", systemImage: "plus") {
                    modelContext.insert(AircraftProfile())
                }
                .accessibilityIdentifier("aircraft.add")
            }
        }
    }

    private func subtitle(for profile: AircraftProfile) -> String {
        var parts: [String] = []
        if !profile.typeDesignator.isEmpty { parts.append(profile.typeDesignator) }
        if profile.cruiseTrueAirspeedKt > 0 { parts.append("\(profile.cruiseTrueAirspeedKt) kt") }
        if profile.fuelBurnGph > 0 { parts.append(String(format: "%.1f gph", profile.fuelBurnGph)) }
        return parts.isEmpty ? "Not configured" : parts.joined(separator: " · ")
    }
}

struct AircraftEditorView: View {
    @Bindable var aircraft: AircraftProfile

    var body: some View {
        Form {
            Section("Identification") {
                field("Tail number", "N123AB", $aircraft.tailNumber)
                field("ICAO type designator", "C172", $aircraft.typeDesignator)
                field("Home base", "KAUS", $aircraft.homeBase)
            }
            Section("ICAO equipment") {
                field("Equipment (Item 10a)", "SBG", $aircraft.equipment)
                field("Surveillance (Item 10b)", "EB1", $aircraft.surveillanceEquipment)
                Picker("Wake category", selection: $aircraft.wakeCategory) {
                    Text("Light (L)").tag("L")
                    Text("Medium (M)").tag("M")
                    Text("Heavy (H)").tag("H")
                }
            }
            Section("Performance") {
                LabeledContent("Cruise TAS (kt)") {
                    TextField("120", value: $aircraft.cruiseTrueAirspeedKt, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Fuel burn (gph)") {
                    TextField("9.5", value: $aircraft.fuelBurnGph, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .navigationTitle(aircraft.tailNumber.isEmpty ? "New Aircraft" : aircraft.tailNumber)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func field(_ label: String, _ prompt: String, _ text: Binding<String>) -> some View {
        LabeledContent(label) {
            TextField(prompt, text: text)
                .font(.body.monospaced())
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .multilineTextAlignment(.trailing)
        }
    }
}

#Preview {
    NavigationStack {
        AircraftListView()
    }
    .modelContainer(for: AircraftProfile.self, inMemory: true)
}
