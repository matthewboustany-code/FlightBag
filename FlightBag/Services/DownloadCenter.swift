import Foundation
import CryptoKit
import FBModels

/// Orchestrates region downloads: manifest state, per-product phases,
/// verification + installation of finished transfers, and refcounted
/// deletion of shared artifacts.
///
/// Two kinds of persisted truth (downloads/state.json):
///  - `records` — user intent: "keep region X's kinds Y offline". Drives
///    what to (re)download each cycle.
///  - `installed` — disk facts per artifact (paths, coverage, plate dirs),
///    kept so deletion refcounting works with no manifest available.
/// Installed-ness itself is always re-derivable from disk; state.json going
/// missing only loses intent, not charts.
@MainActor
@Observable
final class DownloadCenter {
    enum Phase: Equatable {
        case queued
        case downloading(Double)
        case paused
        case verifying
        case installing
        case installed
        case failed(String)
    }

    struct RegionDownloadRecord: Codable, Equatable {
        var regionId: String
        var kinds: Set<DownloadProduct.ContentKind>
        var cycle: String
    }

    /// One installed artifact's disk facts.
    struct InstalledArtifact: Codable, Equatable {
        var productId: String
        var contentKind: DownloadProduct.ContentKind
        var regionIds: [String]
        var cycle: String
        /// Path relative to the cycles root, e.g. "2607/tiles/x.mbtiles".
        /// Empty for plate bundles (their files are the airport dirs).
        var relativePath: String
        /// Airport directories a plates bundle installed under
        /// `{cycle}/plates/`; used for refcounted delete.
        var plateAirportIds: [String]
    }

    private(set) var manifest: DownloadManifest?
    private(set) var manifestError: String?
    private(set) var phases: [String: Phase] = [:]
    private(set) var records: [RegionDownloadRecord] = []
    private(set) var installed: [String: InstalledArtifact] = [:]
    /// Bumped whenever chart files change on disk so the map re-scans.
    private(set) var chartsVersion = 0

    private var service: DownloadService!
    private let manifestClient = ManifestClient()
    private let cyclesRoot: URL
    private let stateURL: URL

    init() {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        cyclesRoot = support.appendingPathComponent("FlightBag/cycles", isDirectory: true)
        stateURL = support.appendingPathComponent("FlightBag/downloads/state.json")
        loadState()
        reconcileWithDisk()

        service = DownloadService(events: .init(
            progress: { [weak self] productId, fraction, _ in
                guard let self, self.phases[productId] != .paused else { return }
                self.phases[productId] = .downloading(fraction)
            },
            finished: { [weak self] productId, staged in
                self?.handleFinished(productId: productId, staged: staged)
            },
            failed: { [weak self] productId, message in
                self?.phases[productId] = .failed(message)
            }
        ))

        Task {
            for productId in await service.reattach() {
                if phases[productId] == nil { phases[productId] = .downloading(0) }
            }
        }
    }

    // MARK: Manifest

    func refreshManifest() async {
        if let fetched = await manifestClient.fetch() {
            manifest = fetched
            manifestError = nil
        } else if manifest == nil {
            manifestError = ServerConfig.baseURL == nil
                ? "No download server configured (Settings → Server)."
                : "Download server unreachable and nothing cached."
        }
    }

    var regions: [Region] { manifest?.regions ?? [] }

    /// Products serving a region for the given kinds (current cycle's list).
    func products(regionId: String, kinds: Set<DownloadProduct.ContentKind>) -> [DownloadProduct] {
        (manifest?.products ?? [])
            .filter { kinds.contains($0.contentKind) && $0.regionIds.contains(regionId) }
            .sorted { $0.title < $1.title }
    }

    // MARK: Download / pause / delete

    func startDownload(regionId: String, kinds: Set<DownloadProduct.ContentKind>) {
        guard let manifest else { return }
        if let index = records.firstIndex(where: { $0.regionId == regionId }) {
            records[index].kinds.formUnion(kinds)
            records[index].cycle = manifest.cycle
        } else {
            records.append(RegionDownloadRecord(regionId: regionId, kinds: kinds, cycle: manifest.cycle))
        }
        saveState()

        for product in products(regionId: regionId, kinds: kinds) {
            guard installed[product.id] == nil else { continue }
            switch phases[product.id] {
            case .queued, .downloading, .verifying, .installing:
                continue
            default:
                phases[product.id] = .queued
                service.start(product)
            }
        }
    }

    func pause(productId: String) {
        phases[productId] = .paused
        service.pause(productId: productId)
    }

    func resume(productId: String) {
        guard let product = product(for: productId) else { return }
        phases[productId] = .queued
        service.start(product)
    }

    func cancel(productId: String) {
        service.cancel(productId: productId)
        phases[productId] = nil
    }

    func retry(productId: String) {
        resume(productId: productId)
    }

    /// Drop the region's record and delete artifacts no remaining region
    /// claims (shared sectionals survive while a neighbor still wants them).
    func deleteRegion(regionId: String) {
        for product in products(regionId: regionId, kinds: Set(DownloadProduct.ContentKind.allCases)) {
            switch phases[product.id] {
            case .queued, .downloading, .paused:
                cancel(productId: product.id)
            default:
                break
            }
        }
        records.removeAll { $0.regionId == regionId }

        for artifact in installed.values where !isClaimed(artifact) {
            removeFromDisk(artifact)
            installed[artifact.productId] = nil
            phases[artifact.productId] = nil
        }
        saveState()
        chartsVersion += 1
    }

    // MARK: Status

    struct RegionStatus: Equatable {
        var installedCount = 0
        var totalCount = 0
        var activeFraction: Double?   // non-nil while anything is transferring
        var failed = false
        var isComplete: Bool { totalCount > 0 && installedCount == totalCount }
    }

    func regionStatus(_ regionId: String) -> RegionStatus {
        var status = RegionStatus()
        guard let record = records.first(where: { $0.regionId == regionId }) else { return status }
        let wanted = products(regionId: regionId, kinds: record.kinds)
        status.totalCount = wanted.count
        var fractions: [Double] = []
        for product in wanted {
            if installed[product.id] != nil {
                status.installedCount += 1
                continue
            }
            switch phases[product.id] {
            case .downloading(let fraction): fractions.append(fraction)
            case .queued, .verifying, .installing: fractions.append(0)
            case .failed: status.failed = true
            default: break
            }
        }
        if !fractions.isEmpty {
            status.activeFraction = fractions.reduce(0, +) / Double(fractions.count)
        }
        return status
    }

    func isInstalled(_ productId: String) -> Bool { installed[productId] != nil }

    func phase(for productId: String) -> Phase? {
        if installed[productId] != nil { return .installed }
        return phases[productId]
    }

    /// Regions (other than `regionId`) already claiming this product — the
    /// "already downloaded via Oklahoma" UI hint.
    func otherClaimants(of product: DownloadProduct, besides regionId: String) -> [String] {
        records
            .filter { $0.regionId != regionId && product.regionIds.contains($0.regionId) && $0.kinds.contains(product.contentKind) }
            .map(\.regionId)
    }

    // MARK: Install pipeline

    private func product(for productId: String) -> DownloadProduct? {
        guard let manifest else { return nil }
        return (manifest.products + manifest.nextCycleProducts).first { $0.id == productId }
    }

    private func handleFinished(productId: String, staged: URL) {
        guard let product = product(for: productId) else {
            phases[productId] = .failed("Product no longer in manifest")
            return
        }
        phases[productId] = .verifying
        let cyclesRoot = cyclesRoot
        Task.detached(priority: .utility) {
            do {
                let artifact = try Self.verifyAndInstall(product: product, staged: staged, cyclesRoot: cyclesRoot)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.installed[product.id] = artifact
                    self.phases[product.id] = .installed
                    self.evictSupersededCycles(of: artifact)
                    self.saveState()
                    // Plates don't affect the map, but bumping anyway lets
                    // storage displays key off one change counter.
                    self.chartsVersion += 1
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.phases[product.id] = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// Off-main: hash-verify the staged file, then land it in the cycles
    /// tree. Throws on any mismatch; the staged file is always consumed.
    nonisolated private static func verifyAndInstall(
        product: DownloadProduct, staged: URL, cyclesRoot: URL
    ) throws -> InstalledArtifact {
        defer { try? FileManager.default.removeItem(at: staged) }

        let digest = try streamingSHA256(of: staged)
        guard digest == product.sha256.lowercased() else {
            throw DownloadError("Checksum mismatch — the download may be corrupt. Try again.")
        }

        var artifact = InstalledArtifact(
            productId: product.id,
            contentKind: product.contentKind,
            regionIds: product.regionIds,
            cycle: product.cycle,
            relativePath: "",
            plateAirportIds: []
        )
        switch product.contentKind {
        case .vfrSectional, .ifrEnrouteLow, .ifrEnrouteHigh, .basemap:
            let relative = "\(product.cycle)/tiles/\(product.url.lastPathComponent)"
            let target = cyclesRoot.appendingPathComponent(relative)
            try install(staged, into: target)
            // Record what the manifest said this chart is. ChartStore would
            // otherwise have to re-derive it from the filename, which only
            // works while filenames follow FAA conventions.
            try? Data(product.contentKind.rawValue.utf8)
                .write(to: target.appendingPathExtension("kind"), options: .atomic)
            artifact.relativePath = relative
        case .aeroDatabase:
            let relative = "\(product.cycle)/aero.sqlite"
            try install(staged, into: cyclesRoot.appendingPathComponent(relative))
            artifact.relativePath = relative
        case .plates:
            let platesDir = cyclesRoot.appendingPathComponent("\(product.cycle)/plates", isDirectory: true)
            try FileManager.default.createDirectory(at: platesDir, withIntermediateDirectories: true)
            let airportIds = try ZipExtractor.extract(zipAt: staged, to: platesDir)
            excludeFromBackup(platesDir)
            artifact.plateAirportIds = airportIds.sorted()
        case .terrain:
            throw DownloadError("Terrain downloads are not supported yet")
        }
        return artifact
    }

    nonisolated private static func install(_ staged: URL, into target: URL) throws {
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: staged, to: target)
        excludeFromBackup(target)
    }

    nonisolated private static func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try? mutable.setResourceValues(values)
    }

    nonisolated static func streamingSHA256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A newly installed tile shadows same-named files from other cycles
    /// (ChartStore already prefers the newest); reclaim the space once the
    /// new cycle's copy is effective.
    private func evictSupersededCycles(of artifact: InstalledArtifact) {
        guard !artifact.relativePath.isEmpty,
              let cycle = DataCycle(id: artifact.cycle), cycle.effectiveDate <= Date() else { return }
        let fileName = (artifact.relativePath as NSString).lastPathComponent
        guard let cycleDirs = try? FileManager.default.contentsOfDirectory(atPath: cyclesRoot.path) else { return }
        for dir in cycleDirs where dir != artifact.cycle {
            guard let other = DataCycle(id: dir), other < cycle else { continue }
            let stale = cyclesRoot.appendingPathComponent("\(dir)/tiles/\(fileName)")
            if FileManager.default.fileExists(atPath: stale.path) {
                try? FileManager.default.removeItem(at: stale)
                try? FileManager.default.removeItem(at: stale.appendingPathExtension("kind"))
                installed = installed.filter { $0.value.relativePath != "\(dir)/tiles/\(fileName)" }
            }
        }
    }

    // MARK: Refcounting & disk

    /// An artifact is claimed while any record wants its kind for a region
    /// it covers.
    private func isClaimed(_ artifact: InstalledArtifact) -> Bool {
        records.contains { record in
            record.kinds.contains(artifact.contentKind) && artifact.regionIds.contains(record.regionId)
        }
    }

    private func removeFromDisk(_ artifact: InstalledArtifact) {
        if !artifact.relativePath.isEmpty {
            let url = cyclesRoot.appendingPathComponent(artifact.relativePath)
            try? FileManager.default.removeItem(at: url)
            // Tile sets carry a `.kind` sidecar; leaving it behind would make
            // a deleted chart look present to a future scan.
            try? FileManager.default.removeItem(at: url.appendingPathExtension("kind"))
        }
        // Plates: remove this bundle's airport dirs unless another installed
        // bundle also provides them.
        let othersAirports = Set(installed.values
            .filter { $0.productId != artifact.productId && $0.contentKind == .plates }
            .flatMap(\.plateAirportIds))
        for airportId in artifact.plateAirportIds where !othersAirports.contains(airportId) {
            try? FileManager.default.removeItem(
                at: cyclesRoot.appendingPathComponent("\(artifact.cycle)/plates/\(airportId)")
            )
        }
    }

    // MARK: Demo seeding

    /// `-downloadsDemoSeed YES`: deterministic manifest + in-flight state for
    /// simctl screenshots, no server required. Never persisted.
    func seedDemo() {
        let cycle = DataCycle.current().id
        func product(_ id: String, _ kind: DownloadProduct.ContentKind, _ title: String, _ regions: [String], _ megabytes: Int64) -> DownloadProduct {
            DownloadProduct(
                id: "\(cycle)/x/\(id)", contentKind: kind, title: title, cycle: cycle,
                regionIds: regions, url: URL(string: "https://example.invalid/\(id)")!,
                sizeBytes: megabytes << 20, sha256: ""
            )
        }
        let products = [
            product("San_Antonio_sectional.mbtiles", .vfrSectional, "San Antonio Sectional", ["US-TX"], 212),
            product("Dallas-Ft_Worth_sectional.mbtiles", .vfrSectional, "Dallas-Ft Worth Sectional", ["US-TX", "US-OK"], 189),
            product("Houston_sectional.mbtiles", .vfrSectional, "Houston Sectional", ["US-TX", "US-LA"], 174),
            product("ENR_L15_ifr_low.mbtiles", .ifrEnrouteLow, "ENR L15 IFR Low", ["US-TX", "US-OK", "US-LA"], 96),
            product("plates_US-TX_\(cycle).zip", .plates, "Texas Terminal Procedures", ["US-TX"], 460),
            product("basemap_us_z0-8.mbtiles", .basemap, "Offline Basemap", ["US-TX", "US-OK", "US-LA", "US-RI"], 310),
        ]
        manifest = DownloadManifest(
            generatedAt: Date(),
            cycle: cycle,
            regions: [
                Region(id: "US-TX", name: "Texas", authority: .faa, kind: .stateOrProvince),
                Region(id: "US-OK", name: "Oklahoma", authority: .faa, kind: .stateOrProvince),
                Region(id: "US-LA", name: "Louisiana", authority: .faa, kind: .stateOrProvince),
                Region(id: "US-RI", name: "Rhode Island", authority: .faa, kind: .stateOrProvince),
            ],
            products: products
        )
        records = [RegionDownloadRecord(regionId: "US-TX", kinds: [.vfrSectional, .ifrEnrouteLow, .plates], cycle: cycle)]
        installed = [products[0].id: InstalledArtifact(
            productId: products[0].id, contentKind: .vfrSectional, regionIds: ["US-TX"],
            cycle: cycle, relativePath: "\(cycle)/tiles/San_Antonio_sectional.mbtiles", plateAirportIds: []
        )]
        phases = [
            products[1].id: .downloading(0.42),
            products[2].id: .queued,
            products[3].id: .downloading(0.87),
            products[4].id: .paused,
        ]
    }

    // MARK: Persistence

    private struct PersistedState: Codable {
        var records: [RegionDownloadRecord]
        var installed: [String: InstalledArtifact]
    }

    private func loadState() {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else { return }
        records = state.records
        installed = state.installed
    }

    private func saveState() {
        let state = PersistedState(records: records, installed: installed)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: stateURL, options: .atomic)
    }

    /// Disk is truth for installed-ness: drop entries whose files vanished
    /// (user cleared storage, reinstalling, …).
    private func reconcileWithDisk() {
        installed = installed.filter { _, artifact in
            if !artifact.relativePath.isEmpty {
                return FileManager.default.fileExists(atPath: cyclesRoot.appendingPathComponent(artifact.relativePath).path)
            }
            // Plates: alive while any of its airport dirs remain.
            return artifact.plateAirportIds.contains { airportId in
                FileManager.default.fileExists(atPath: cyclesRoot.appendingPathComponent("\(artifact.cycle)/plates/\(airportId)").path)
            }
        }
    }
}

struct DownloadError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
