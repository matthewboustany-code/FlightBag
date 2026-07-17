import SwiftUI
import FBModels

/// Offline data status: installed database cycle, chart regions, plate
/// storage, freshness.
struct DownloadsHomeView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var plateBytes: Int64 = 0
    @State private var chartBytes: Int64 = 0
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
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
                chartRegionsSection
                Section("Storage") {
                    LabeledContent("Chart Tiles", value: ByteCountFormatter.string(fromByteCount: chartBytes, countStyle: .file))
                    LabeledContent("Approach Plates", value: ByteCountFormatter.string(fromByteCount: plateBytes, countStyle: .file))
                    Text("Plates viewed on an airport page are also kept offline automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Downloads")
            .navigationDestination(for: String.self) { regionId in
                RegionDetailView(regionId: regionId)
            }
            .task {
                if UserDefaults.standard.bool(forKey: "downloadsDemoSeed") {
                    environment.downloadCenter.seedDemo()
                    // `-downloadsDemoOpen US-TX` deep-links into a region's
                    // detail screen for screenshot automation.
                    if let regionId = UserDefaults.standard.string(forKey: "downloadsDemoOpen") {
                        path.append(regionId)
                    }
                } else {
                    await environment.downloadCenter.refreshManifest()
                    // `-downloadsDemoAutostart US-TX`: simulator verification
                    // hook — kicks off a real region download with no taps.
                    if let regionId = UserDefaults.standard.string(forKey: "downloadsDemoAutostart") {
                        let kinds = Set(environment.downloadCenter.products(
                            regionId: regionId,
                            kinds: Set(DownloadProduct.ContentKind.allCases)
                        ).map(\.contentKind))
                        environment.downloadCenter.startDownload(regionId: regionId, kinds: kinds)
                    }
                }
                await refreshStorage()
            }
            .refreshable {
                await environment.downloadCenter.refreshManifest()
                await refreshStorage()
            }
            // Keep storage figures live as installs/deletes complete.
            .task(id: environment.downloadCenter.chartsVersion) {
                await refreshStorage()
            }
        }
    }

    private var center: DownloadCenter { environment.downloadCenter }

    @ViewBuilder
    private var chartRegionsSection: some View {
        Section {
            if center.records.isEmpty {
                Text("No regions downloaded. Add a region to keep its charts and procedures available offline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(center.records, id: \.regionId) { record in
                NavigationLink(value: record.regionId) {
                    RegionRow(record: record)
                }
            }
            NavigationLink {
                RegionListView()
            } label: {
                Label("Add Region", systemImage: "plus.circle")
                    .foregroundStyle(Color.accentColor)
            }
            .accessibilityIdentifier("downloads.addRegion")
        } header: {
            Text("Chart Regions")
        } footer: {
            if let error = center.manifestError {
                Text(error).foregroundStyle(.orange)
            }
        }
    }

    private func refreshStorage() async {
        plateBytes = await environment.plateStore.storedByteCount()
        let store = environment.chartStore
        chartBytes = await Task.detached { store.storedByteCount() }.value
    }
}

/// One downloaded (or downloading) region in the Downloads list.
private struct RegionRow: View {
    @Environment(AppEnvironment.self) private var environment
    let record: DownloadCenter.RegionDownloadRecord

    var body: some View {
        let center = environment.downloadCenter
        let status = center.regionStatus(record.regionId)
        let name = center.regions.first { $0.id == record.regionId }?.name ?? record.regionId
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(subtitle(for: status))
                    .font(.caption)
                    .foregroundStyle(status.failed ? .orange : .secondary)
            }
            Spacer()
            if let fraction = status.activeFraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.circular)
            } else if status.isComplete, let cycle = DataCycle(id: record.cycle) {
                FreshnessBadge(freshness: cycle.freshness())
            }
        }
    }

    private func subtitle(for status: DownloadCenter.RegionStatus) -> String {
        let items = status.totalCount == 1 ? "item" : "items"
        if status.failed { return "Some downloads failed — tap to retry" }
        if let fraction = status.activeFraction {
            return "Downloading… \(Int(fraction * 100))% · \(status.installedCount)/\(status.totalCount) \(items)"
        }
        if status.isComplete { return "\(status.totalCount) \(items) offline" }
        return "\(status.installedCount)/\(status.totalCount) \(items) offline"
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

/// Freshness for a product: explicit expiration (56-day IFR editions) wins
/// over cycle math, so IFR charts don't read "expired" a cycle early.
func productFreshness(_ product: DownloadProduct, at date: Date = Date()) -> DataCycle.Freshness {
    if let expiration = product.expirationDate {
        if let cycle = DataCycle(id: product.cycle), cycle.effectiveDate > date { return .notYetEffective }
        if date >= expiration { return .expired }
        if expiration.timeIntervalSince(date) <= 5 * 86_400 { return .expiring }
        return .current
    }
    return DataCycle(id: product.cycle)?.freshness(at: date) ?? .current
}

#Preview {
    DownloadsHomeView()
        .environment(AppEnvironment())
}
