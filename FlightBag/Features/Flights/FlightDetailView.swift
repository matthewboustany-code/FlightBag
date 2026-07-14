import SwiftUI
import SwiftData
import FBModels
import FBFlightPlan

/// One flight: route editing with live resolution, and entry points into the
/// ICAO plan, navlog, clearances, and documents.
struct FlightDetailView: View {
    @Bindable var flight: Flight
    @Environment(AppEnvironment.self) private var environment
    @Query(sort: \AircraftProfile.tailNumber) private var aircraft: [AircraftProfile]

    @State private var parsedRoute: ParsedRoute?
    @State private var demoPushPlan = false
    @State private var demoPushNavLog = false

    var body: some View {
        Form {
            routeSection
            aircraftSection
            planningSection
            clearancesSection
            DocumentsSection(flight: flight)
            Section("Notes") {
                TextField("Notes", text: $flight.notes, axis: .vertical)
                    .lineLimit(2...6)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $demoPushPlan) {
            FlightPlanFormView(flight: flight)
        }
        .navigationDestination(isPresented: $demoPushNavLog) {
            NavLogView(flight: flight, parsedRoute: parsedRoute)
        }
        .task(id: fullRouteString) {
            await resolveRoute()
        }
        .task {
            // `-flightsDemoScreen plan|filing|navlog` deep-links for
            // screenshot automation (navlog waits for route resolution).
            switch UserDefaults.standard.string(forKey: "flightsDemoScreen") {
            case "plan", "filing":
                demoPushPlan = true
            case "navlog":
                while parsedRoute == nil {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                demoPushNavLog = true
            case "map":
                while parsedRoute == nil {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                showOnMap()
            default:
                break
            }
        }
    }

    private var title: String {
        flight.departure.isEmpty && flight.destination.isEmpty
            ? "New Flight"
            : "\(flight.departure) → \(flight.destination)"
    }

    /// Departure, en-route string, and destination as one parseable route.
    private var fullRouteString: String {
        [flight.departure, flight.routeString, flight.destination]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: Route

    private var routeSection: some View {
        Section("Route") {
            HStack {
                AirportField(label: "From", text: $flight.departure)
                Divider()
                AirportField(label: "To", text: $flight.destination)
            }
            TextField("Route (e.g. CWK V17 ACT, or DCT)", text: $flight.routeString, axis: .vertical)
                .font(.body.monospaced())
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .accessibilityIdentifier("flight.route")

            if let parsedRoute {
                RouteResolutionView(route: parsedRoute)
            }

            Button {
                showOnMap()
            } label: {
                Label("Show on Map", systemImage: "map")
            }
            .disabled((parsedRoute?.waypoints.count ?? 0) < 2)
            .accessibilityIdentifier("flight.showOnMap")
        }
    }

    private func resolveRoute() async {
        guard let db = environment.aeroDatabase, !fullRouteString.isEmpty else {
            parsedRoute = nil
            return
        }
        parsedRoute = try? await RouteParser(resolver: db).parse(fullRouteString)
    }

    private func showOnMap() {
        guard let parsedRoute else { return }
        environment.activeMapRoute = ActiveMapRoute(
            label: "\(flight.departure) → \(flight.destination)",
            coordinates: parsedRoute.waypoints.map(\.coordinate)
        )
        environment.requestedTab = .map
    }

    // MARK: Aircraft

    private var aircraftSection: some View {
        Section("Aircraft") {
            Picker("Aircraft", selection: $flight.aircraft) {
                Text("None").tag(AircraftProfile?.none)
                ForEach(aircraft) { profile in
                    Text("\(profile.tailNumber) — \(profile.typeDesignator)")
                        .tag(Optional(profile))
                }
            }
            NavigationLink("Manage Aircraft") {
                AircraftListView()
            }
        }
    }

    // MARK: Planning

    private var planningSection: some View {
        Section("Planning") {
            NavigationLink {
                FlightPlanFormView(flight: flight)
            } label: {
                LabeledContent("ICAO Flight Plan") {
                    if let plan = FlightPlanCodec.decode(flight.flightPlanData) {
                        Text("\(plan.flightRules.rawValue) · \(plan.cruisingSpeed) · \(plan.cruisingLevel)")
                            .font(.callout.monospaced())
                    } else {
                        Text("Not started")
                    }
                }
            }
            .accessibilityIdentifier("flight.plan")

            NavigationLink {
                NavLogView(flight: flight, parsedRoute: parsedRoute)
            } label: {
                LabeledContent("Navigation Log") {
                    if let parsedRoute, parsedRoute.waypoints.count >= 2 {
                        Text("\(Int(parsedRoute.distanceNM.rounded())) NM")
                    } else {
                        Text("Needs route")
                    }
                }
            }
            .accessibilityIdentifier("flight.navlog")
        }
    }

    // MARK: Clearances

    private var clearancesSection: some View {
        Section("Clearances") {
            ForEach(flight.clearances ?? []) { clearance in
                NavigationLink {
                    ClearanceEntryView(clearance: clearance)
                } label: {
                    VStack(alignment: .leading) {
                        Text(clearance.clearanceLimit.isEmpty ? "Clearance" : "Cleared to \(clearance.clearanceLimit)")
                            .font(.callout)
                        Text(clearance.receivedAt, format: .dateTime.month().day().hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Button {
                let clearance = ClearanceRecord()
                clearance.flight = flight
                flight.clearances = (flight.clearances ?? []) + [clearance]
            } label: {
                Label("Record Clearance", systemImage: "plus")
            }
            .accessibilityIdentifier("flight.addClearance")
        }
    }
}

/// Compact uppercase airport-identifier field.
private struct AirportField: View {
    let label: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField("KAUS", text: $text)
                .font(.title3.monospaced().bold())
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .accessibilityIdentifier("flight.\(label.lowercased())")
        }
    }
}

/// Resolution summary under the route field: distance, expanded airways,
/// and unresolved tokens.
private struct RouteResolutionView: View {
    let route: ParsedRoute

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if route.waypoints.count >= 2 {
                Label(
                    "\(Int(route.distanceNM.rounded())) NM · \(route.waypoints.count) waypoints",
                    systemImage: "point.topleft.down.to.point.bottomright.curvepath"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            ForEach(airwaySummaries, id: \.self) { summary in
                Label(summary, systemImage: "road.lanes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !route.unresolvedIdentifiers.isEmpty {
                Label(
                    "Not found: \(route.unresolvedIdentifiers.joined(separator: ", "))",
                    systemImage: "questionmark.circle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
    }

    private var airwaySummaries: [String] {
        route.elements.compactMap { element in
            guard case .airway(let ident, let via) = element else { return nil }
            return via.isEmpty
                ? "\(ident): enter and exit fixes must be on the airway"
                : "\(ident) via \(via.count) fixes"
        }
    }
}

#Preview {
    NavigationStack {
        FlightDetailView(flight: Flight(departure: "KAUS", destination: "KDAL", routeString: "CWK V17 ACT"))
    }
    .modelContainer(for: Flight.self, inMemory: true)
    .environment(AppEnvironment())
}
