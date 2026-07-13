import SwiftUI
import FBModels

/// Offline data status: installed database cycle, plate storage, freshness.
/// Chart tile regions join this list in Phase 2.
struct DownloadsHomeView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var storedBytes: Int64 = 0

    var body: some View {
        NavigationStack {
            List {
                if let cycle = environment.aeroDatabase?.cycle {
                    Section("Airport & Navigation Database") {
                        LabeledContent("AIRAC Cycle", value: cycle.id)
                        LabeledContent("Effective", value: cycle.effectiveDate.formatted(date: .abbreviated, time: .omitted))
                        LabeledContent("Expires", value: cycle.expirationDate.formatted(date: .abbreviated, time: .omitted))
                        LabeledContent("Status") {
                            FreshnessBadge(freshness: cycle.freshness())
                        }
                    }
                } else {
                    Section {
                        Label("Aviation database unavailable", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
                Section("Approach Plates") {
                    LabeledContent("Stored Offline", value: ByteCountFormatter.string(fromByteCount: storedBytes, countStyle: .file))
                    Text("Download plates per airport from the airport page. Anything viewed once stays available offline.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Chart Regions") {
                    Text("Sectional and IFR chart downloads arrive in Phase 2.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Downloads")
            .task {
                storedBytes = await environment.plateStore.storedByteCount()
            }
            .refreshable {
                storedBytes = await environment.plateStore.storedByteCount()
            }
        }
    }
}

struct FreshnessBadge: View {
    let freshness: DataCycle.Freshness

    var body: some View {
        Text(label)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        switch freshness {
        case .current: "Current"
        case .expiring: "Expiring Soon"
        case .expired: "Expired"
        case .notYetEffective: "Not Yet Effective"
        }
    }

    private var color: Color {
        switch freshness {
        case .current: .green
        case .expiring: .orange
        case .expired: .red
        case .notYetEffective: .blue
        }
    }
}

#Preview {
    DownloadsHomeView()
        .environment(AppEnvironment())
}
