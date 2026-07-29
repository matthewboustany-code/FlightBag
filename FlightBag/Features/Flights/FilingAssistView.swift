import SwiftUI
import UIKit
import FBModels
import FBFlightPlan
import FBProviders

/// Assisted filing: the validated plan rendered in ICAO form-field order with
/// tap-to-copy per field, plus the 1800wxbrief handoff. Direct Leidos filing
/// slots in behind `FilingService` when partner credentials arrive.
struct FilingAssistView: View {
    let plan: ICAOFlightPlan
    @Environment(AppEnvironment.self) private var environment

    @State private var copiedField: String?
    @State private var receipt: FilingReceipt?

    private var issues: [ValidationIssue] {
        FlightPlanValidator.validate(plan)
    }

    private var errors: [ValidationIssue] {
        issues.filter { $0.severity == .error }
    }

    var body: some View {
        List {
            if errors.isEmpty {
                Section {
                    Label("Plan passes all \(ValidationIssue.Field.allCases.count) field checks", systemImage: "checkmark.seal")
                        .foregroundStyle(.green)
                }
            } else {
                Section("Fix before filing") {
                    ForEach(errors) { issue in
                        Label(issue.message, systemImage: "exclamationmark.circle")
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }

            Section {
                ForEach(fieldRows, id: \.label) { row in
                    CopyRow(
                        label: row.label,
                        value: row.value,
                        copied: copiedField == row.label
                    ) {
                        UIPasteboard.general.string = row.value
                        copiedField = row.label
                    }
                }
            } header: {
                Text("ICAO form fields — tap to copy")
            } footer: {
                Text("Fields appear in 1800wxbrief's form order. Copy each one across, then file there.")
            }

            Section {
                // The handoff target is the only regional part of filing.
                // Offering a US portal for an EDDF→LFPG plan would send a
                // pilot somewhere that cannot accept it; saving a draft and
                // validating still work anywhere.
                if Jurisdiction.forIdentifier(plan.departure).supports(.assistedFiling) {
                    Link(destination: URL(string: "https://www.1800wxbrief.com")!) {
                        Label("Open 1800wxbrief.com", systemImage: "safari")
                    }
                    .accessibilityIdentifier("filing.wxbrief")
                } else {
                    CapabilityNotice(capability: .assistedFiling)
                        .accessibilityIdentifier("filing.unsupportedRegion")
                }

                Button {
                    Task { await saveDraft() }
                } label: {
                    Label("Save Draft in FlightBag", systemImage: "tray.and.arrow.down")
                }
                .accessibilityIdentifier("filing.saveDraft")

                if let receipt {
                    Label(receipt.message ?? receipt.status.rawValue.capitalized, systemImage: receiptIcon(receipt))
                        .font(.callout)
                        .foregroundStyle(receipt.status == .rejected ? Color.red : Color.secondary)
                }
            } footer: {
                Text("FlightBag never transmits to ATC. File with Flight Service (1800wxbrief.com or 1-800-WX-BRIEF) and treat their acknowledgment as authoritative.")
            }
        }
        .navigationTitle("File Flight Plan")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func saveDraft() async {
        receipt = try? await environment.filingService.file(plan, as: .local)
    }

    private func receiptIcon(_ receipt: FilingReceipt) -> String {
        switch receipt.status {
        case .draft: "tray.full"
        case .filed: "paperplane.fill"
        case .rejected: "xmark.octagon"
        case .cancelled: "minus.circle"
        }
    }

    /// The plan in exact ICAO item order, formatted the way each wxbrief form
    /// field expects it.
    private var fieldRows: [(label: String, value: String)] {
        var rows: [(String, String)] = [
            ("7 · Aircraft Identification", plan.aircraftIdentification),
            ("8 · Flight Rules", plan.flightRules.rawValue),
            ("8 · Type of Flight", plan.flightType.rawValue),
            ("9 · Number", String(plan.numberOfAircraft)),
            ("9 · Type of Aircraft", plan.aircraftType),
            ("9 · Wake Turbulence Cat.", plan.wakeTurbulenceCategory.rawValue),
            ("10a · Equipment", plan.equipment),
            ("10b · Surveillance", plan.surveillanceEquipment),
            ("13 · Departure Aerodrome", plan.departure.rawValue),
            ("13 · Time (UTC)", Self.hhmm.string(from: plan.departureTime)),
            ("15 · Cruising Speed", plan.cruisingSpeed),
            ("15 · Level", plan.cruisingLevel),
            ("15 · Route", plan.route),
            ("16 · Destination Aerodrome", plan.destination.rawValue),
            ("16 · Total EET", plan.totalEET),
        ]
        if let alternate = plan.alternate1 {
            rows.append(("16 · Alternate", alternate.rawValue))
        }
        if let alternate2 = plan.alternate2 {
            rows.append(("16 · 2nd Alternate", alternate2.rawValue))
        }
        if !plan.otherInformation.isEmpty {
            rows.append(("18 · Other Information", plan.otherInformation))
        }
        if let endurance = plan.fuelEndurance {
            rows.append(("19 · Endurance", endurance))
        }
        if let pob = plan.personsOnBoard {
            rows.append(("19 · Persons on Board", String(pob)))
        }
        if let pic = plan.pilotInCommand, !pic.isEmpty {
            rows.append(("19 · Pilot in Command", pic))
        }
        if let remarks = plan.remarks, !remarks.isEmpty {
            rows.append(("19 · Remarks", remarks))
        }
        return rows
    }

    private static let hhmm: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "HHmm"
        return formatter
    }()
}

private struct CopyRow: View {
    let label: String
    let value: String
    let copied: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(value.isEmpty ? "—" : value)
                        .font(.body.monospaced())
                        .foregroundStyle(.primary)
                }
                Spacer()
                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    .foregroundStyle(copied ? Color.green : Color.accentColor)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    NavigationStack {
        FilingAssistView(plan: ICAOFlightPlan(
            aircraftIdentification: "N123AB",
            aircraftType: "C172",
            equipment: "SBG",
            surveillanceEquipment: "EB1",
            departure: ICAOIdentifier("KAUS"),
            cruisingSpeed: "N0120",
            cruisingLevel: "A070",
            route: "CWK V17 ACT",
            destination: ICAOIdentifier("KDAL"),
            totalEET: "0115",
            alternate1: ICAOIdentifier("KFTW"),
            fuelEndurance: "0430",
            personsOnBoard: 2
        ))
    }
    .environment(AppEnvironment())
}
