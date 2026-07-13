import SwiftUI
import SwiftData

/// Phase 3 builds this out: flight list, ICAO flight plan form + filing,
/// clearance recording, and per-flight documents.
struct FlightsHomeView: View {
    @Query(sort: \Flight.createdAt, order: .reverse) private var flights: [Flight]

    var body: some View {
        NavigationStack {
            Group {
                if flights.isEmpty {
                    ContentUnavailableView(
                        "No Flights Yet",
                        systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                        description: Text("Create a flight to plan a route, file IFR, record clearances, and attach documents.")
                    )
                } else {
                    List(flights) { flight in
                        VStack(alignment: .leading) {
                            Text("\(flight.departure) → \(flight.destination)")
                                .font(.headline)
                            Text(flight.createdAt, style: .date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Flights")
        }
    }
}

#Preview {
    FlightsHomeView()
        .modelContainer(for: Flight.self, inMemory: true)
}
