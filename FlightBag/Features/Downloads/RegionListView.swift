import SwiftUI
import FBModels

/// Pick a region to download — rendered entirely from the manifest, so new
/// coverage (states today, countries later) needs no app change.
///
/// Three ways in, because they answer different questions: the download button
/// on a row takes the whole region as published, tapping the row opens its
/// detail view for per-kind control, and "Select" turns the list into a
/// multi-select — with 70+ regions published, going into each one to tick the
/// same boxes is the slow path.
struct RegionListView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var searchText = ""
    @State private var isSelecting = false
    @State private var selectedRegions: Set<String> = []
    @State private var choosingKinds = false
    @State private var confirmingWholeRegion: Region?

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
                if isSelecting {
                    Button {
                        toggle(region.id)
                    } label: {
                        HStack {
                            Image(systemName: selectedRegions.contains(region.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedRegions.contains(region.id) ? Color.accentColor : .secondary)
                            Text(region.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            statusLabel(for: region.id)
                        }
                        // The Spacer is empty space, and a plain button's hit
                        // area is only its content — without this, tapping the
                        // middle of a row does nothing at all.
                        .contentShape(Rectangle())
                    }
                    // Without .plain the whole row renders as accent-coloured
                    // link text, which reads as "already selected".
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("region.select.\(region.id)")
                } else {
                    HStack {
                        NavigationLink(value: DownloadsRoute.region(region.id)) {
                            HStack {
                                Text(region.name)
                                Spacer()
                                statusLabel(for: region.id)
                            }
                        }
                        wholeRegionButton(for: region)
                    }
                }
            }
        }
        .navigationTitle("Add Region")
        .searchable(text: $searchText, prompt: "Search regions")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if center.regions.isEmpty {
                    EmptyView()
                } else if isSelecting {
                    Button("Cancel") {
                        isSelecting = false
                        selectedRegions.removeAll()
                    }
                } else {
                    Button("Select") { isSelecting = true }
                        .accessibilityIdentifier("regions.select")
                }
            }
        }
        // Not toolbar(.bottomBar): this screen lives inside the app's TabView,
        // and a bottom-bar item renders underneath the tab bar where it cannot
        // be tapped. A safe-area inset sits above it correctly.
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                selectionBar
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                    .background(.bar)
            }
        }
        .sheet(isPresented: $choosingKinds) {
            BulkDownloadSheet(regionIds: selectedRegions) {
                isSelecting = false
                selectedRegions.removeAll()
            }
        }
        .confirmationDialog(
            "Download this whole region?",
            isPresented: Binding(
                get: { confirmingWholeRegion != nil },
                set: { if !$0 { confirmingWholeRegion = nil } }
            ),
            titleVisibility: .visible,
            presenting: confirmingWholeRegion
        ) { region in
            Button("Download \(ByteCountFormatter.string(fromByteCount: remainingBytes(for: region.id), countStyle: .file))") {
                environment.downloadCenter.startDownload(
                    regionId: region.id,
                    kinds: publishedKinds(for: region.id)
                )
            }
            .accessibilityIdentifier("regions.wholeRegion.confirm")
        } message: { region in
            Text("Keeps everything published for \(region.name) offline: \(kindSummary(for: region.id)).")
        }
        .task {
            await environment.downloadCenter.refreshManifest()
        }
    }

    /// One tap for "all of it", so taking a whole state does not mean opening
    /// it and ticking every box. Absent once everything published is already
    /// installed — the row's checkmark says so.
    @ViewBuilder
    private func wholeRegionButton(for region: Region) -> some View {
        if remainingBytes(for: region.id) > 0 {
            Button {
                confirmingWholeRegion = region
            } label: {
                Image(systemName: "arrow.down.circle")
                    .imageScale(.large)
            }
            // .borderless keeps the tap to the icon; a plain button in a row
            // with a NavigationLink otherwise swallows the whole row.
            .buttonStyle(.borderless)
            .accessibilityLabel("Download all of \(region.name)")
            .accessibilityIdentifier("region.downloadAll.\(region.id)")
        }
    }

    /// Every content kind the manifest publishes for a region.
    private func publishedKinds(for regionId: String) -> Set<DownloadProduct.ContentKind> {
        Set(environment.downloadCenter
            .products(regionId: regionId, kinds: Set(DownloadProduct.ContentKind.allCases))
            .map(\.contentKind))
    }

    /// Bytes still to fetch for the whole region — what isn't already on the
    /// device, so a shared sectional isn't counted against a second state.
    private func remainingBytes(for regionId: String) -> Int64 {
        let center = environment.downloadCenter
        return center.products(regionId: regionId, kinds: Set(DownloadProduct.ContentKind.allCases))
            .filter { !center.isInstalled($0.id) }
            .reduce(0) { $0 + $1.sizeBytes }
    }

    private func kindSummary(for regionId: String) -> String {
        let names = publishedKinds(for: regionId)
            .sorted { $0.rawValue < $1.rawValue }
            .map(\.displayName)
        return names.isEmpty ? "nothing yet" : names.formatted(.list(type: .and))
    }

    private var selectionBar: some View {
        HStack {
            // Scoped to what is on screen, so it composes with search rather
            // than silently selecting 70 regions the user cannot see.
            Button(allFilteredSelected ? "Deselect All" : "Select All") {
                if allFilteredSelected {
                    selectedRegions.subtract(filteredRegions.map(\.id))
                } else {
                    selectedRegions.formUnion(filteredRegions.map(\.id))
                }
            }
            Spacer()
            Button {
                choosingKinds = true
            } label: {
                Text(selectedRegions.isEmpty
                     ? "Download"
                     : "Download \(selectedRegions.count) Region\(selectedRegions.count == 1 ? "" : "s")")
                    .fontWeight(.semibold)
            }
            .disabled(selectedRegions.isEmpty)
            .accessibilityIdentifier("regions.downloadSelected")
        }
    }

    private var allFilteredSelected: Bool {
        let ids = filteredRegions.map(\.id)
        return !ids.isEmpty && ids.allSatisfy { selectedRegions.contains($0) }
    }

    private func toggle(_ regionId: String) {
        if selectedRegions.contains(regionId) {
            selectedRegions.remove(regionId)
        } else {
            selectedRegions.insert(regionId)
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

/// Chart types to apply across every selected region, chosen once.
private struct BulkDownloadSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let regionIds: Set<String>
    let onStart: () -> Void

    @State private var selectedKinds: Set<DownloadProduct.ContentKind> = [.plates]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(DownloadProduct.ContentKind.offeredPerRegion, id: \.self) { kind in
                        let size = totalSize(for: [kind])
                        Toggle(isOn: binding(for: kind)) {
                            HStack {
                                Text(kind.displayName)
                                Spacer()
                                Text(size == 0
                                     ? "Not published"
                                     : ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(size == 0)
                    }
                } header: {
                    Text("Chart Types")
                } footer: {
                    Text("Applied to all \(regionIds.count) selected region\(regionIds.count == 1 ? "" : "s"). Sizes count each chart once even when several regions share it.")
                        .font(.caption)
                }

                Section {
                    let total = totalSize(for: selectedKinds)
                    Button {
                        for regionId in regionIds {
                            environment.downloadCenter.startDownload(regionId: regionId, kinds: selectedKinds)
                        }
                        onStart()
                        dismiss()
                    } label: {
                        Label(
                            total == 0
                                ? "Choose a Chart Type"
                                : "Download \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))",
                            systemImage: "arrow.down.circle.fill"
                        )
                    }
                    .disabled(total == 0)
                    .accessibilityIdentifier("regions.bulkDownload.confirm")
                }
            }
            .navigationTitle("\(regionIds.count) Region\(regionIds.count == 1 ? "" : "s")")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                // Plates are the usual default, but a server that has not
                // published them for these regions would otherwise show a lit
                // toggle sitting next to the words "Not published".
                selectedKinds = selectedKinds.filter { totalSize(for: [$0]) > 0 }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    /// Charts are shared between regions (one sectional covers several states),
    /// so sum distinct products — adding per-region totals would overstate the
    /// download badly across a wide selection.
    private func totalSize(for kinds: Set<DownloadProduct.ContentKind>) -> Int64 {
        guard !kinds.isEmpty else { return 0 }
        var seen: Set<String> = []
        var total: Int64 = 0
        for regionId in regionIds {
            for product in environment.downloadCenter.products(regionId: regionId, kinds: kinds)
            where seen.insert(product.id).inserted {
                total += product.sizeBytes
            }
        }
        return total
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

#Preview {
    NavigationStack {
        RegionListView()
    }
    .environment(AppEnvironment())
}
