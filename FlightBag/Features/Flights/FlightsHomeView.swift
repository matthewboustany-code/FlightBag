import SwiftUI
import SwiftData

/// Flight list: create, open, and delete planned flights.
struct FlightsHomeView: View {
    @Query(sort: \Flight.createdAt, order: .reverse) private var flights: [Flight]
    @Environment(\.modelContext) private var modelContext
    @State private var path: [Flight] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if flights.isEmpty {
                    ContentUnavailableView {
                        Label("No Flights Yet", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    } description: {
                        Text("Create a flight to plan a route, build an ICAO flight plan, record clearances, and attach documents.")
                    } actions: {
                        Button("New Flight", action: createFlight)
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(flights) { flight in
                            NavigationLink(value: flight) {
                                FlightRow(flight: flight)
                            }
                        }
                        .onDelete { offsets in
                            for offset in offsets {
                                modelContext.delete(flights[offset])
                            }
                        }
                    }
                }
            }
            .navigationTitle("Flights")
            .navigationDestination(for: Flight.self) { flight in
                FlightDetailView(flight: flight)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("New Flight", systemImage: "plus", action: createFlight)
                        .accessibilityIdentifier("flights.new")
                }
            }
            .task {
                // Launch-argument demo/automation hook: seed a KAUS→KDAL
                // flight (with aircraft) so screenshots have real content.
                guard UserDefaults.standard.bool(forKey: "flightsDemoSeed") else { return }
                if let existing = flights.first {
                    path = [existing]
                } else {
                    let aircraft = AircraftProfile(tailNumber: "N123AB")
                    aircraft.typeDesignator = "C172"
                    aircraft.equipment = "SBG"
                    aircraft.surveillanceEquipment = "EB1"
                    aircraft.cruiseTrueAirspeedKt = 115
                    aircraft.fuelBurnGph = 8.5
                    aircraft.homeBase = "KAUS"
                    modelContext.insert(aircraft)
                    let flight = Flight(departure: "KAUS", destination: "KDAL", routeString: "CWK V17 ACT")
                    flight.aircraft = aircraft
                    modelContext.insert(flight)
                    path = [flight]
                }
            }
        }
    }

    private func createFlight() {
        let flight = Flight()
        modelContext.insert(flight)
        path.append(flight)
    }
}

private struct FlightRow: View {
    let flight: Flight

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(flight.departure.isEmpty ? "————" : flight.departure)
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(flight.destination.isEmpty ? "————" : flight.destination)
            }
            .font(.headline.monospaced())
            HStack(spacing: 8) {
                Text(flight.createdAt, style: .date)
                if !flight.routeString.isEmpty {
                    Text(flight.routeString)
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    FlightsHomeView()
        .modelContainer(for: Flight.self, inMemory: true)
        .environment(AppEnvironment())
}
