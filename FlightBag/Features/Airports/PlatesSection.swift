import SwiftUI
import FBModels

/// Approach plates and other terminal procedures, grouped by category, with
/// per-airport offline prefetch.
struct PlatesSection: View {
    let plates: [PlateMetadata]

    @Environment(AppEnvironment.self) private var environment
    @State private var downloadProgress: (done: Int, total: Int)?
    @State private var downloadedCount = 0

    var body: some View {
        Section {
            if plates.isEmpty {
                Text("No published procedures").foregroundStyle(.secondary)
            }
            ForEach(orderedCategories, id: \.self) { category in
                DisclosureGroup("\(category.displayName) (\(grouped[category]?.count ?? 0))") {
                    ForEach(grouped[category] ?? []) { plate in
                        NavigationLink(value: plate) {
                            Text(plate.chartName)
                                .font(.callout)
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text("Procedures")
                Spacer()
                if let progress = downloadProgress {
                    Text("\(progress.done)/\(progress.total)")
                        .font(.caption)
                        .monospacedDigit()
                } else if !plates.isEmpty {
                    let allDownloaded = downloadedCount >= plates.count && downloadedCount > 0
                    Button(allDownloaded ? "Offline ✓" : "Download All") {
                        downloadAll()
                    }
                    .font(.caption)
                    .disabled(allDownloaded)
                }
            }
        }
        .task(id: plates) {
            downloadedCount = await environment.plateStore.downloadedCount(for: plates)
        }
    }

    private var grouped: [PlateMetadata.Category: [PlateMetadata]] {
        Dictionary(grouping: plates, by: \.category)
    }

    private var orderedCategories: [PlateMetadata.Category] {
        let order: [PlateMetadata.Category] = [.airportDiagram, .approach, .arrival, .departure, .minimums, .other]
        return order.filter { grouped[$0]?.isEmpty == false }
    }

    private func downloadAll() {
        let store = environment.plateStore
        let plates = plates
        downloadProgress = (0, plates.count)
        Task {
            _ = await store.downloadAll(plates) { done, total in
                Task { @MainActor in
                    downloadProgress = (done, total)
                }
            }
            downloadProgress = nil
            downloadedCount = await store.downloadedCount(for: plates)
        }
    }
}
