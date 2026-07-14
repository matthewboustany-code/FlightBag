import SwiftUI
import SwiftData
import FBModels
import FBFlightPlan
import FBProviders

/// Serialize the ICAO plan into `Flight.flightPlanData` — a JSON blob so the
/// SwiftData schema doesn't mirror every FPL field.
enum FlightPlanCodec {
    static func decode(_ data: Data?) -> ICAOFlightPlan? {
        data.flatMap { try? JSONDecoder().decode(ICAOFlightPlan.self, from: $0) }
    }

    static func encode(_ plan: ICAOFlightPlan) -> Data? {
        try? JSONEncoder().encode(plan)
    }
}

/// ICAO FPL form. Every field validates live through the shared
/// `FlightPlanValidator` — the same rules that gate filing.
struct FlightPlanFormView: View {
    @Bindable var flight: Flight

    @State private var plan = ICAOFlightPlan()
    @State private var loaded = false
    @State private var demoPushFiling = false

    private var issues: [ValidationIssue] {
        FlightPlanValidator.validate(plan)
    }

    var body: some View {
        Form {
            Section("Aircraft — Items 7–10") {
                validatedField("Aircraft ID (N123AB)", text: $plan.aircraftIdentification, field: .aircraftIdentification)
                Picker("Flight rules", selection: $plan.flightRules) {
                    ForEach(ICAOFlightPlan.FlightRules.allCases, id: \.self) { rules in
                        Text(label(for: rules)).tag(rules)
                    }
                }
                validatedField("Type designator (C172)", text: $plan.aircraftType, field: .aircraftType)
                Picker("Wake category", selection: $plan.wakeTurbulenceCategory) {
                    ForEach(ICAOFlightPlan.WakeTurbulenceCategory.allCases, id: \.self) { wake in
                        Text(wake.rawValue).tag(wake)
                    }
                }
                validatedField("Equipment (SBG)", text: $plan.equipment, field: .equipment)
                validatedField("Surveillance (EB1)", text: $plan.surveillanceEquipment, field: .surveillanceEquipment)
                if let aircraft = flight.aircraft {
                    Button {
                        autofill(from: aircraft)
                    } label: {
                        Label("Autofill from \(aircraft.tailNumber)", systemImage: "sparkles")
                    }
                }
            }

            Section("Departure — Item 13") {
                validatedField("Departure (KAUS)", text: icaoBinding($plan.departure), field: .departure)
                DatePicker("Off-block (UTC)", selection: $plan.departureTime)
                issueFooter(.departureTime)
            }

            Section("Route — Item 15") {
                validatedField("Cruising speed (N0120)", text: $plan.cruisingSpeed, field: .cruisingSpeed)
                validatedField("Level (A070)", text: $plan.cruisingLevel, field: .cruisingLevel)
                VStack(alignment: .leading) {
                    TextField("Route (CWK V17 ACT or DCT)", text: $plan.route, axis: .vertical)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    issueFooter(.route)
                }
            }

            Section("Destination — Item 16") {
                validatedField("Destination (KDAL)", text: icaoBinding($plan.destination), field: .destination)
                validatedField("Total EET (0130)", text: $plan.totalEET, field: .totalEET)
                validatedField("Alternate", text: optionalIcaoBinding($plan.alternate1), field: .alternate1)
                validatedField("2nd alternate", text: optionalIcaoBinding($plan.alternate2), field: .alternate2)
            }

            Section("Other information — Item 18") {
                TextField("PBN/, DOF/, RMK/ …", text: $plan.otherInformation, axis: .vertical)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            }

            Section("Supplementary — Item 19") {
                validatedField("Endurance (0430)", text: optionalBinding($plan.fuelEndurance), field: .fuelEndurance)
                VStack(alignment: .leading) {
                    TextField("Persons on board", value: $plan.personsOnBoard, format: .number)
                        .keyboardType(.numberPad)
                    issueFooter(.personsOnBoard)
                }
                TextField("Pilot in command", text: optionalBinding($plan.pilotInCommand))
                TextField("Remarks", text: optionalBinding($plan.remarks), axis: .vertical)
            }

            Section {
                NavigationLink {
                    FilingAssistView(plan: plan)
                } label: {
                    Label(
                        errorCount == 0 ? "File…" : "File… (\(errorCount) errors to fix)",
                        systemImage: "paperplane"
                    )
                }
                .accessibilityIdentifier("plan.file")
            } footer: {
                Text("Filing is assisted: FlightBag validates the plan and hands each field to 1800wxbrief.com. Nothing is transmitted from this app.")
            }
        }
        .navigationTitle("ICAO Flight Plan")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $demoPushFiling) {
            FilingAssistView(plan: plan)
        }
        .task {
            load()
            if UserDefaults.standard.string(forKey: "flightsDemoScreen") == "filing" {
                demoPushFiling = true
            }
        }
        .onChange(of: plan) { save() }
    }

    private var errorCount: Int {
        issues.filter { $0.severity == .error }.count
    }

    // MARK: Load/save

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let stored = FlightPlanCodec.decode(flight.flightPlanData) {
            plan = stored
            return
        }
        // Seed a fresh plan from the flight and its aircraft.
        plan.departure = ICAOIdentifier(flight.departure.uppercased())
        plan.destination = ICAOIdentifier(flight.destination.uppercased())
        plan.route = flight.routeString.isEmpty ? "DCT" : flight.routeString.uppercased()
        if let aircraft = flight.aircraft {
            autofill(from: aircraft)
        }
    }

    private func save() {
        flight.flightPlanData = FlightPlanCodec.encode(plan)
        // Keep the flight's list-level fields in sync with the plan.
        if !plan.departure.rawValue.isEmpty { flight.departure = plan.departure.rawValue }
        if !plan.destination.rawValue.isEmpty { flight.destination = plan.destination.rawValue }
        if !plan.route.isEmpty, plan.route != "DCT" { flight.routeString = plan.route }
    }

    private func autofill(from aircraft: AircraftProfile) {
        plan.aircraftIdentification = aircraft.tailNumber.uppercased()
        plan.aircraftType = aircraft.typeDesignator.uppercased()
        plan.equipment = aircraft.equipment.uppercased()
        plan.surveillanceEquipment = aircraft.surveillanceEquipment.uppercased()
        plan.wakeTurbulenceCategory = ICAOFlightPlan.WakeTurbulenceCategory(rawValue: aircraft.wakeCategory) ?? .light
        if aircraft.cruiseTrueAirspeedKt > 0 {
            plan.cruisingSpeed = String(format: "N%04d", aircraft.cruiseTrueAirspeedKt)
        }
    }

    // MARK: Field helpers

    private func validatedField(_ label: String, text: Binding<String>, field: ValidationIssue.Field) -> some View {
        VStack(alignment: .leading) {
            TextField(label, text: text)
                .font(.body.monospaced())
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .accessibilityIdentifier("plan.\(field.rawValue)")
            issueFooter(field)
        }
    }

    @ViewBuilder
    private func issueFooter(_ field: ValidationIssue.Field) -> some View {
        ForEach(issues.filter { $0.field == field }) { issue in
            Label(issue.message, systemImage: issue.severity == .error ? "exclamationmark.circle" : "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(issue.severity == .error ? Color.red : Color.orange)
        }
    }

    private func icaoBinding(_ binding: Binding<ICAOIdentifier>) -> Binding<String> {
        Binding(
            get: { binding.wrappedValue.rawValue },
            set: { binding.wrappedValue = ICAOIdentifier($0.uppercased()) }
        )
    }

    private func optionalIcaoBinding(_ binding: Binding<ICAOIdentifier?>) -> Binding<String> {
        Binding(
            get: { binding.wrappedValue?.rawValue ?? "" },
            set: { binding.wrappedValue = $0.isEmpty ? nil : ICAOIdentifier($0.uppercased()) }
        )
    }

    private func optionalBinding(_ binding: Binding<String?>) -> Binding<String> {
        Binding(
            get: { binding.wrappedValue ?? "" },
            set: { binding.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }

    private func label(for rules: ICAOFlightPlan.FlightRules) -> String {
        switch rules {
        case .ifr: "IFR (I)"
        case .vfr: "VFR (V)"
        case .yankee: "IFR then VFR (Y)"
        case .zulu: "VFR then IFR (Z)"
        }
    }
}

#Preview {
    NavigationStack {
        FlightPlanFormView(flight: Flight(departure: "KAUS", destination: "KDAL", routeString: "CWK V17 ACT"))
    }
    .modelContainer(for: Flight.self, inMemory: true)
    .environment(AppEnvironment())
}
