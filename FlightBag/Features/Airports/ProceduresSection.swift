import SwiftUI
import FBModels

/// Departures/Arrivals from the CIFP procedure tables, each with a
/// "show on map" action that draws the procedure's branches as a vector
/// preview. Hidden entirely when the database predates procedures
/// (schema < 3) or the airport has none.
struct ProceduresSection: View {
    let airport: Airport

    @Environment(AppEnvironment.self) private var environment
    @State private var procedures: [AeroDatabase.ProcedureSummary] = []

    var body: some View {
        Group {
            let sids = procedures.filter { $0.kind == "sid" }
            let stars = procedures.filter { $0.kind == "star" }
            if !sids.isEmpty || !stars.isEmpty {
                Section {
                    if !sids.isEmpty {
                        DisclosureGroup("Departures (\(sids.count))") {
                            ForEach(sids, id: \.self, content: row)
                        }
                    }
                    if !stars.isEmpty {
                        DisclosureGroup("Arrivals (\(stars.count))") {
                            ForEach(stars, id: \.self, content: row)
                        }
                    }
                } header: {
                    Text("Procedures")
                } footer: {
                    Text("Drawn from FAA coded procedure data (all transitions). A preview for orientation — fly the published chart.")
                        .font(.caption)
                }
            }
        }
        .task(id: airport.id) {
            guard let db = environment.aeroDatabase else { return }
            procedures = (try? await db.procedures(airportId: airport.id, icaoId: airport.icaoId?.rawValue)) ?? []
        }
    }

    private func row(_ procedure: AeroDatabase.ProcedureSummary) -> some View {
        HStack {
            Text(procedure.ident)
                .font(.body.monospaced())
            Spacer()
            Button {
                showOnMap(procedure)
            } label: {
                Image(systemName: "map")
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("procedure.showOnMap.\(procedure.ident)")
        }
    }

    private func showOnMap(_ procedure: AeroDatabase.ProcedureSummary) {
        Task {
            guard let db = environment.aeroDatabase,
                  let legs = try? await db.procedureLegs(airportId: airport.id, icaoId: airport.icaoId?.rawValue, ident: procedure.ident),
                  !legs.isEmpty else { return }
            environment.activeProcedure = ActiveMapProcedure(
                airportDisplayId: airport.displayIdentifier,
                ident: procedure.ident,
                kind: procedure.kind,
                legs: legs
            )
            environment.requestedTab = .map
        }
    }
}
