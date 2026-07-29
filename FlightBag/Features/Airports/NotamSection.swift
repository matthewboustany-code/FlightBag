import SwiftUI
import FBModels

/// NOTAMs for one airport, age-stamped, falling back to the cached copy when
/// the server is unreachable.
///
/// Every empty case says *why* it's empty. A bare empty list would read as
/// "nothing is wrong at this airport", which is the one conclusion a pilot
/// must never draw from a failed fetch.
struct NotamSection: View {
    let station: ICAOIdentifier
    let jurisdiction: Jurisdiction

    @Environment(AppEnvironment.self) private var environment
    @State private var result: NotamStore.Result?
    @State private var isLoading = true

    var body: some View {
        Section {
            if !jurisdiction.supports(.notams) {
                CapabilityNotice(capability: .notams)
            } else if isLoading && result == nil {
                HStack {
                    ProgressView()
                    Text("Fetching NOTAMs…").foregroundStyle(.secondary)
                }
            } else if let result {
                content(result)
            }
        } header: {
            HStack {
                Text("NOTAMs")
                Spacer()
                if jurisdiction.supports(.notams) {
                    Button {
                        Task { await refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .font(.caption)
                    .accessibilityIdentifier("notams.refresh")
                }
            }
        }
        .task(id: RefreshKey(station: station, fisbVersion: environment.fisbNotamVersion)) {
            await refresh()
        }
    }

    @ViewBuilder
    private func content(_ result: NotamStore.Result) -> some View {
        if !result.notams.isEmpty {
            ageStamp(result)
            ForEach(result.notams) { notam in
                NotamRow(notam: notam)
            }
        }
        switch result.availability {
        case .available:
            if result.notams.isEmpty {
                Text("No NOTAMs published for \(station.rawValue).")
                    .foregroundStyle(.secondary)
            }
        case .noServerConfigured:
            unavailable(
                "NOTAMs need a FlightBag server — set one in Settings.",
                systemImage: "server.rack"
            )
        case .serverMissingCredentials:
            unavailable(
                "The FlightBag server has no FAA NOTAM credentials configured.",
                systemImage: "key.slash"
            )
        case .unreachable:
            unavailable(
                result.notams.isEmpty
                    ? "Couldn't reach the NOTAM service, and none are cached. Check official sources."
                    : "Couldn't reach the NOTAM service — showing cached NOTAMs. Check official sources.",
                systemImage: "exclamationmark.triangle"
            )
        }
    }

    private func unavailable(_ message: String, systemImage: String) -> some View {
        Label {
            Text(message).font(.callout)
        } icon: {
            Image(systemName: systemImage)
        }
        .foregroundStyle(.orange)
    }

    @ViewBuilder
    private func ageStamp(_ result: NotamStore.Result) -> some View {
        HStack(spacing: 6) {
            if result.source == .fisb {
                Label("via ADS-B", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            Spacer()
            if let fetchedAt = result.fetchedAt {
                Text(result.isStale
                    ? "Cached · \(fetchedAt, style: .relative) ago"
                    : "Updated \(fetchedAt, style: .relative) ago")
                    .font(.caption)
                    .foregroundStyle(result.isStale ? .orange : .secondary)
            }
        }
    }

    private func refresh() async {
        isLoading = true
        defer { isLoading = false }
        result = await environment.notamStore.notams(for: station)
    }

    /// Re-runs the fetch when a FIS-B uplink delivers new NOTAMs, so they
    /// appear in flight without tapping refresh.
    private struct RefreshKey: Equatable {
        let station: ICAOIdentifier
        let fisbVersion: Int
    }
}

/// One NOTAM: its number, validity, and text. Long notices truncate to three
/// lines and expand on tap — a plate-closure NOTAM can run to a paragraph and
/// would otherwise push everything else off the screen.
struct NotamRow: View {
    let notam: Notam

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(notam.id)
                    .font(.caption.monospaced().weight(.semibold))
                if !notam.isActive() {
                    Text("EXPIRED")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: .rect(cornerRadius: 4))
                }
                Spacer()
                validity
            }
            Text(notam.text)
                .font(.callout)
                .lineLimit(isExpanded ? nil : 3)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .onTapGesture {
            withAnimation(.snappy) { isExpanded.toggle() }
        }
        .opacity(notam.isActive() ? 1 : 0.6)
    }

    @ViewBuilder
    private var validity: some View {
        if let end = notam.effectiveEnd, !notam.endIsEstimated {
            Text("until \(end, format: .dateTime.month().day().hour().minute())")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if notam.endIsEstimated {
            // PERM/EST NOTAMs have no dependable end; saying "until <date>"
            // would overstate what the source published.
            Text("no end time")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
