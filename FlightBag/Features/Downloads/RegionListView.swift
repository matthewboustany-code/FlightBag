import SwiftUI
import FBModels

/// Pick a region to download — rendered entirely from the manifest, so new
/// coverage (states today, countries later) needs no app change.
struct RegionListView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var searchText = ""

    var body: some View {
        let center = environment.downloadCenter
        List {
            if center.regions.isEmpty {
                ContentUnavailableView(
                    "No Regions Available",
                    systemImage: "square.and.arrow.down",
                    description: Text(center.manifestError ?? "Connect to the internet once to load the region list.")
                )
            }
            ForEach(filteredRegions) { region in
                NavigationLink(value: region.id) {
                    HStack {
                        Text(region.name)
                        Spacer()
                        statusLabel(for: region.id)
                    }
                }
            }
        }
        .navigationTitle("Add Region")
        .navigationDestination(for: String.self) { regionId in
            RegionDetailView(regionId: regionId)
        }
        .searchable(text: $searchText, prompt: "Search states")
        .task {
            await environment.downloadCenter.refreshManifest()
        }
    }

    private var filteredRegions: [Region] {
        let regions = environment.downloadCenter.regions
        guard !searchText.isEmpty else { return regions }
        return regions.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    @ViewBuilder
    private func statusLabel(for regionId: String) -> some View {
        let status = environment.downloadCenter.regionStatus(regionId)
        if status.isComplete {
            Label("Downloaded", systemImage: "checkmark.circle.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(.green)
        } else if status.activeFraction != nil {
            ProgressView()
        } else if status.totalCount > 0 {
            Text("\(status.installedCount)/\(status.totalCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    NavigationStack {
        RegionListView()
    }
    .environment(AppEnvironment())
}
