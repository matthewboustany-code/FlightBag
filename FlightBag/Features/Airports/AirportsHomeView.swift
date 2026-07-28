import SwiftUI
import FBModels

/// Airport search backed by the offline FTS index, with recents.
struct AirportsHomeView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var searchText = ""
    @State private var results: [AeroDatabase.SearchResult] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var path = NavigationPath()
    @State private var coverage: (airports: Int, countries: Int)?
    @AppStorage("recentAirports") private var recentAirportsStorage = ""

    private var recentIdentifiers: [String] {
        recentAirportsStorage.split(separator: ",").map(String.init)
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if searchText.isEmpty {
                    if !recentIdentifiers.isEmpty {
                        Section("Recent") {
                            ForEach(recentIdentifiers, id: \.self) { ident in
                                NavigationLink(value: ident) {
                                    Label(ident, systemImage: "clock")
                                }
                            }
                        }
                    } else {
                        ContentUnavailableView(
                            "Search Airports",
                            systemImage: "airplane.arrival",
                            description: Text(coverageText)
                        )
                    }
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    ForEach(results) { result in
                        NavigationLink(value: result.id) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(result.displayIdentifier)
                                        .font(.headline.monospaced())
                                    Text(result.name)
                                        .lineLimit(1)
                                }
                                Text([result.city, result.state].compactMap(\.self).joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Airports")
            .searchable(text: $searchText, prompt: "Airport ID, name, or city")
            .navigationDestination(for: String.self) { airportId in
                AirportDetailView(airportId: airportId, onView: { recordRecent($0) })
            }
            // `-airportsDemoOpen KAUS` deep-links straight to a detail page
            // for screenshot automation.
            .task {
                if let identifier = UserDefaults.standard.string(forKey: "airportsDemoOpen") {
                    path.append(identifier)
                }
                if let db = environment.aeroDatabase {
                    coverage = try? await db.coverageSummary()
                }
            }
            .onChange(of: searchText) { _, newValue in
                searchTask?.cancel()
                searchTask = Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled, let db = environment.aeroDatabase else { return }
                    results = (try? await db.search(newValue)) ?? []
                }
            }
        }
    }

    /// Describes what is actually installed rather than asserting a fixed
    /// number. Approach plates are called out separately because they really
    /// are US-only, and folding them into a worldwide sentence would promise
    /// coverage that does not exist.
    private var coverageText: String {
        guard let coverage else {
            return "Runways, frequencies, and weather — all offline."
        }
        let airports = coverage.airports.formatted(.number.grouping(.automatic))
        return "Runways, frequencies, and weather for \(airports) airports across \(coverage.countries) countries — all offline. Approach plates are US-only."
    }

    private func recordRecent(_ identifier: String) {
        var recents = recentIdentifiers.filter { $0 != identifier }
        recents.insert(identifier, at: 0)
        recentAirportsStorage = recents.prefix(8).joined(separator: ",")
    }
}

#Preview {
    AirportsHomeView()
        .environment(AppEnvironment())
}
