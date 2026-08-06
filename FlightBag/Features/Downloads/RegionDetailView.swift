import SwiftUI
import FBModels

/// One region's chart types: pick what to keep offline, watch progress,
/// delete when done with it.
struct RegionDetailView: View {
    @Environment(AppEnvironment.self) private var environment
    let regionId: String
    @State private var selectedKinds: Set<DownloadProduct.ContentKind> = []
    @State private var confirmingDelete = false

    var body: some View {
        let center = environment.downloadCenter
        let record = center.records.first { $0.regionId == regionId }
        List {
            kindSelectionSection(record: record)
            downloadButtonSection(record: record)
            productsSection(record: record)
            if record != nil {
                Section {
                    Button("Delete Region", role: .destructive) {
                        confirmingDelete = true
                    }
                    .accessibilityIdentifier("region.delete")
                } footer: {
                    Text("Charts shared with another downloaded region stay on this device until the last region using them is deleted.")
                        .font(.caption)
                }
            }
        }
        .navigationTitle(regionName)
        .confirmationDialog("Delete \(regionName)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Downloads", role: .destructive) {
                environment.downloadCenter.deleteRegion(regionId: regionId)
            }
        } message: {
            Text("Removes this region's offline charts and procedures.")
        }
        .task {
            // Preselect what's already kept offline.
            if let record = environment.downloadCenter.records.first(where: { $0.regionId == regionId }) {
                selectedKinds = record.kinds
            }
        }
    }

    private var regionName: String {
        environment.downloadCenter.regions.first { $0.id == regionId }?.name ?? regionId
    }

    // MARK: Sections

    private func kindSelectionSection(record: DownloadCenter.RegionDownloadRecord?) -> some View {
        Section {
            ForEach(DownloadProduct.ContentKind.offeredPerRegion, id: \.self) { kind in
                let products = environment.downloadCenter.products(regionId: regionId, kinds: [kind])
                let size = products.reduce(Int64(0)) { $0 + $1.sizeBytes }
                Toggle(isOn: binding(for: kind)) {
                    HStack {
                        Text(kind.displayName)
                        Spacer()
                        Text(products.isEmpty
                            ? "Not yet published"
                            : ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(products.isEmpty)
            }
        } header: {
            Text("Chart Types")
        } footer: {
            Text("Sizes are totals for this region; charts already on this device from another region don't download again.")
                .font(.caption)
        }
    }

    @ViewBuilder
    private func downloadButtonSection(record: DownloadCenter.RegionDownloadRecord?) -> some View {
        let newKinds = selectedKinds.subtracting(record?.kinds ?? [])
        if !newKinds.isEmpty || record == nil {
            Section {
                Button {
                    environment.downloadCenter.startDownload(regionId: regionId, kinds: selectedKinds)
                } label: {
                    Label("Download Selected", systemImage: "arrow.down.circle.fill")
                }
                .disabled(selectedKinds.isEmpty)
                .accessibilityIdentifier("region.download")
            }
        }
    }

    @ViewBuilder
    private func productsSection(record: DownloadCenter.RegionDownloadRecord?) -> some View {
        let kinds = (record?.kinds ?? []).union(selectedKinds)
        let products = environment.downloadCenter.products(regionId: regionId, kinds: kinds)
        if !products.isEmpty {
            Section("Items") {
                ForEach(products) { product in
                    ProductRow(product: product, regionId: regionId)
                }
            }
        }
    }

    private func binding(for kind: DownloadProduct.ContentKind) -> Binding<Bool> {
        Binding(
            get: { selectedKinds.contains(kind) },
            set: { on in
                if on { selectedKinds.insert(kind) } else { selectedKinds.remove(kind) }
            }
        )
    }
}

/// One artifact's row: title, freshness, size, live phase controls.
private struct ProductRow: View {
    @Environment(AppEnvironment.self) private var environment
    let product: DownloadProduct
    let regionId: String

    var body: some View {
        let center = environment.downloadCenter
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(product.title)
                HStack(spacing: 6) {
                    Text(ByteCountFormatter.string(fromByteCount: product.sizeBytes, countStyle: .file))
                    if case .installed = center.phase(for: product.id) {
                        FreshnessBadge(freshness: productFreshness(product))
                        let others = center.otherClaimants(of: product, besides: regionId)
                        if !others.isEmpty {
                            Text("shared with \(claimantNames(others))")
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            phaseControls(center.phase(for: product.id))
        }
    }

    private func claimantNames(_ ids: [String]) -> String {
        let regions = environment.downloadCenter.regions
        return ids.map { id in regions.first { $0.id == id }?.name ?? id }.joined(separator: ", ")
    }

    @ViewBuilder
    private func phaseControls(_ phase: DownloadCenter.Phase?) -> some View {
        let center = environment.downloadCenter
        switch phase {
        case .installed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .downloading(let fraction):
            HStack(spacing: 10) {
                ProgressView(value: fraction)
                    .frame(width: 70)
                Button {
                    center.pause(productId: product.id)
                } label: {
                    Image(systemName: "pause.circle")
                }
                .buttonStyle(.plain)
            }
        case .paused:
            Button {
                center.resume(productId: product.id)
            } label: {
                Label("Resume", systemImage: "play.circle")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
        case .queued:
            ProgressView()
        case .verifying, .installing:
            Label("Verifying", systemImage: "checkmark.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Button {
                center.retry(productId: product.id)
            } label: {
                Label("Retry", systemImage: "arrow.clockwise.circle")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .help(message)
        case nil:
            Image(systemName: "arrow.down.circle.dotted")
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    let environment = AppEnvironment()
    NavigationStack {
        RegionDetailView(regionId: "US-TX")
    }
    .environment(environment)
    .task { environment.downloadCenter.seedDemo() }
}
