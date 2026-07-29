import SwiftUI
import FBModels
import FBFlightPlan

/// NOTAMs for every airport on a flight, grouped by station in route order.
///
/// Airports only — see `NotamStore.briefing(for:)`. The screen says so
/// explicitly rather than letting a pilot read enroute silence as "clear".
struct NotamBriefingView: View {
    let flight: Flight
    let parsedRoute: ParsedRoute?

    @Environment(AppEnvironment.self) private var environment
    @State private var briefings: [NotamStore.StationBriefing] = []
    @State private var isLoading = true

    var body: some View {
        List {
            if isLoading && briefings.isEmpty {
                HStack {
                    ProgressView()
                    Text("Briefing \(stations.count) airport\(stations.count == 1 ? "" : "s")…")
                        .foregroundStyle(.secondary)
                }
            } else if stations.isEmpty {
                ContentUnavailableView(
                    "No Airports",
                    systemImage: "airplane.circle",
                    description: Text("Set a departure and destination to brief NOTAMs.")
                )
            } else {
                if let serverIssue {
                    Section {
                        Label(serverIssue, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
                ForEach(briefings) { briefing in
                    section(for: briefing)
                }
                Section {
                    Label(
                        "Airport NOTAMs only. Enroute and area NOTAMs are not included — "
                            + "brief them from an official source.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("NOTAM Briefing")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button {
                Task { await refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityIdentifier("briefing.refresh")
        }
        .task(id: stations.map(\.rawValue).joined()) {
            await refresh()
        }
    }

    @ViewBuilder
    private func section(for briefing: NotamStore.StationBriefing) -> some View {
        Section {
            if !briefing.result.notams.isEmpty {
                ForEach(briefing.result.notams) { notam in
                    NotamRow(notam: notam)
                }
            }
            switch briefing.result.availability {
            case .available where briefing.result.notams.isEmpty:
                Text("No NOTAMs published.").foregroundStyle(.secondary)
            case .available:
                EmptyView()
            // Server-level problems are stated once at the top of the
            // briefing, not repeated under every airport. Here they only
            // need to explain a station that has nothing to show.
            case .noServerConfigured, .serverMissingCredentials:
                if briefing.result.notams.isEmpty {
                    Text("Nothing cached for this airport.").foregroundStyle(.secondary)
                }
            case .unreachable:
                unavailable(
                    briefing.result.notams.isEmpty
                        ? "Couldn't reach the NOTAM service, and none are cached."
                        : "Couldn't reach the NOTAM service — these are cached."
                )
            }
        } header: {
            HStack {
                Text(briefing.station.rawValue)
                Spacer()
                if briefing.result.source == .fisb {
                    Label("via ADS-B", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                if let fetchedAt = briefing.result.fetchedAt {
                    Text(fetchedAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(briefing.result.isStale ? .orange : .secondary)
                }
            }
        }
    }

    private func unavailable(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.orange)
    }

    /// A configuration problem that applies to the whole briefing rather than
    /// to one airport, so it's said once instead of under every station.
    private var serverIssue: String? {
        if briefings.contains(where: { $0.result.availability == .noServerConfigured }) {
            return "No FlightBag server configured — set one in Settings. "
                + "Anything below is cached or came over ADS-B."
        }
        if briefings.contains(where: { $0.result.availability == .serverMissingCredentials }) {
            return "The FlightBag server has no FAA NOTAM credentials. "
                + "Anything below is cached or came over ADS-B."
        }
        return nil
    }

    /// Departure, destination, and any airports the route itself names —
    /// route order, so the briefing reads the way the flight is flown.
    private var stations: [ICAOIdentifier] {
        var result: [ICAOIdentifier] = []
        if !flight.departure.isEmpty { result.append(ICAOIdentifier(flight.departure)) }
        for waypoint in parsedRoute?.waypoints ?? [] where waypoint.kind == .airport {
            result.append(ICAOIdentifier(waypoint.identifier))
        }
        if !flight.destination.isEmpty { result.append(ICAOIdentifier(flight.destination)) }
        return result
    }

    private func refresh() async {
        isLoading = true
        defer { isLoading = false }
        briefings = await environment.notamStore.briefing(for: stations)
    }
}
