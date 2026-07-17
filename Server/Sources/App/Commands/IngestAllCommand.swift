import Vapor
import FBModels

/// One-shot per-cycle orchestrator for the whole ingest pipeline — the
/// command a scheduled job (host cron → `docker compose run --rm ingest`)
/// invokes daily. Cheap when there is nothing to do:
///
///   - picks the target cycle itself (the next cycle once the FAA has
///     published its charts ~20 days early, else the current one),
///   - exits immediately when `{artifacts}/{cycle}/.complete` exists,
///   - skips every artifact whose final file is already in the tree, so a
///     rerun after a mid-pipeline failure resumes where it left off.
///
/// Scope (which sectionals/panels/plate regions to build) comes from
/// FLIGHTBAG_* environment variables so the deployment's .env owns it; see
/// `Scope`. The database always builds — everything else defaults to none.
struct IngestAllCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "cycle", help: "AIRAC cycle id, e.g. 2607. Defaults to the next cycle if the FAA has published it, else the current one.")
        var cycle: String?

        @Option(name: "artifacts", help: "Artifact tree root. Defaults to Public/artifacts")
        var artifacts: String?

        @Option(name: "workdir", help: "Directory for downloads and intermediates. Defaults to /work when present (the compose volume), else .build/ingest")
        var workdir: String?

        @Option(name: "gdal-bin", help: "Directory containing GDAL binaries. Defaults to $PATH lookup.")
        var gdalBin: String?

        @Option(name: "base-url", help: "Absolute URL prefix for product URLs. Defaults to $FLIGHTBAG_BASE_URL, then http://127.0.0.1:8080")
        var baseURL: String?

        init() {}
    }

    var help: String {
        "Run the full ingest pipeline (db, tiles, basemap, plates, manifest) for the upcoming cycle; no-op when already complete"
    }

    // MARK: Environment-driven scope

    /// `all`, `none`, or a comma list; unset means none (the .env owns scope —
    /// a bare `ingest-all` should never surprise anyone with a 100 GB build).
    enum Selection {
        case none
        case all
        case list([String])

        init(environment name: String) {
            let raw = Environment.get(name)?.trimmingCharacters(in: .whitespaces) ?? ""
            switch raw.lowercased() {
            case "", "none": self = .none
            case "all": self = .all
            default: self = .list(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            }
        }
    }

    struct Scope {
        let sectionals: [String]
        let ifrLowPanels: [Int]
        let ifrHighPanels: [Int]
        let plateRegions: [String]
        /// auto = build only when no basemap exists in any cycle directory
        /// (the manifest carries an old one forward, so one build lasts).
        let basemap: String
        let minFreeGB: Int

        static func fromEnvironment() throws -> Scope {
            Scope(
                sectionals: try sectionalNames(Selection(environment: "FLIGHTBAG_SECTIONALS")),
                ifrLowPanels: try panels(Selection(environment: "FLIGHTBAG_IFR_LOW_PANELS"), range: 1...36, name: "FLIGHTBAG_IFR_LOW_PANELS"),
                ifrHighPanels: try panels(Selection(environment: "FLIGHTBAG_IFR_HIGH_PANELS"), range: 1...12, name: "FLIGHTBAG_IFR_HIGH_PANELS"),
                plateRegions: try regionIds(Selection(environment: "FLIGHTBAG_REGIONS")),
                basemap: try basemapPolicy(),
                minFreeGB: Environment.get("FLIGHTBAG_MIN_FREE_GB").flatMap(Int.init) ?? 50
            )
        }

        private static func sectionalNames(_ selection: Selection) throws -> [String] {
            let known = ChartCatalog.vfrSectionals.map(\.fileName)
            switch selection {
            case .none: return []
            case .all: return known
            case .list(let names):
                for name in names where !known.contains(name) {
                    throw Abort(.badRequest, reason: "FLIGHTBAG_SECTIONALS: unknown sectional \"\(name)\" (use FAA file names like San_Antonio)")
                }
                return names
            }
        }

        private static func panels(_ selection: Selection, range: ClosedRange<Int>, name: String) throws -> [Int] {
            switch selection {
            case .none: return []
            case .all: return Array(range)
            case .list(let raw):
                return try raw.map {
                    guard let panel = Int($0), range.contains(panel) else {
                        throw Abort(.badRequest, reason: "\(name): \"\($0)\" is not a panel number in \(range)")
                    }
                    return panel
                }
            }
        }

        private static func regionIds(_ selection: Selection) throws -> [String] {
            switch selection {
            case .none: return []
            case .all: return ChartCatalog.regionIds
            case .list(let raw):
                return try raw.map {
                    let id = $0.uppercased().hasPrefix("US-") ? $0.uppercased() : "US-\($0.uppercased())"
                    guard ChartCatalog.region(id: id) != nil else {
                        throw Abort(.badRequest, reason: "FLIGHTBAG_REGIONS: unknown region \"\($0)\" (use state ids like US-TX)")
                    }
                    return id
                }
            }
        }

        private static func basemapPolicy() throws -> String {
            let policy = Environment.get("FLIGHTBAG_BASEMAP")?.lowercased() ?? "auto"
            guard ["auto", "always", "never"].contains(policy) else {
                throw Abort(.badRequest, reason: "FLIGHTBAG_BASEMAP must be auto, always, or never")
            }
            return policy
        }
    }

    // MARK: Run

    func run(using context: CommandContext, signature: Signature) async throws {
        let console = context.console
        let scope = try Scope.fromEnvironment()

        let artifactsRoot = URL(
            fileURLWithPath: signature.artifacts ?? context.application.directory.publicDirectory + "artifacts",
            isDirectory: true
        )
        let workDir = try resolveWorkDirectory(signature.workdir)
        guard let baseURL = URL(string: signature.baseURL ?? Environment.get("FLIGHTBAG_BASE_URL") ?? "http://127.0.0.1:8080") else {
            throw Abort(.badRequest, reason: "base URL is not a valid URL")
        }
        let pipeline = TilePipeline(workDirectory: workDir, gdalBinDirectory: signature.gdalBin) { console.info($0) }

        let cycle = try await resolveTargetCycle(signature: signature, pipeline: pipeline, console: console)
        let cycleDir = artifactsRoot.appendingPathComponent(cycle.id, isDirectory: true)
        let marker = cycleDir.appendingPathComponent(".complete")

        // The manifest's notion of "current" is always wall-clock current —
        // artifacts built early for the next cycle land in nextCycleProducts
        // until the cycle actually flips.
        let manifestCycle = DataCycle.current()

        if FileManager.default.fileExists(atPath: marker.path) {
            if manifestCycle.id == publishedManifestCycleId(artifactsRoot: artifactsRoot) {
                console.info("Cycle \(cycle.id) already complete and manifest current — nothing to do")
                return
            }
            // Cycle flipped since the last run: same artifacts, but products
            // must move out of nextCycleProducts.
            console.info("Cycle \(cycle.id) complete; rebuilding manifest for new current cycle \(manifestCycle.id)")
            try writeManifest(artifactsRoot: artifactsRoot, baseURL: baseURL, currentCycle: manifestCycle, console: console)
            return
        }

        try ensureFreeSpace(atLeastGB: scope.minFreeGB, at: workDir)
        console.info("Ingest-all for cycle \(cycle.id) → \(cycleDir.path)")

        try await buildDatabase(cycle: cycle, cycleDir: cycleDir, workDir: workDir, console: console)
        try await buildTiles(scope: scope, cycle: cycle, artifactsRoot: artifactsRoot, workDir: workDir, pipeline: pipeline, console: console)
        try await buildBasemap(policy: scope.basemap, cycle: cycle, artifactsRoot: artifactsRoot, workDir: workDir, pipeline: pipeline, console: console)
        try await buildPlates(regions: scope.plateRegions, cycle: cycle, cycleDir: cycleDir, workDir: workDir, console: console)
        try writeManifest(artifactsRoot: artifactsRoot, baseURL: baseURL, currentCycle: manifestCycle, console: console)

        try ISO8601DateFormatter().string(from: Date())
            .write(to: marker, atomically: true, encoding: .utf8)
        pruneWorkCaches(workDir: workDir, keeping: [cycle, cycle.previous()], console: console)
        console.success("Cycle \(cycle.id) ingest complete")
    }

    // MARK: Cycle / environment resolution

    private func resolveTargetCycle(signature: Signature, pipeline: TilePipeline, console: Console) async throws -> DataCycle {
        if let id = signature.cycle {
            guard let parsed = DataCycle(id: id) else {
                throw Abort(.badRequest, reason: "\(id) is not a valid AIRAC cycle identifier")
            }
            return parsed
        }
        let current = DataCycle.current()
        let next = current.next()
        // Any sectional works as the publication probe; San Antonio is small
        // and has existed forever. A failed probe just means "not yet".
        let probe = TilePipeline.Source.sectional(chart: "San_Antonio").remoteURL(for: next)
        if (try? await pipeline.remoteExists(probe)) == true {
            console.info("FAA has published cycle \(next.id) — targeting it")
            return next
        }
        return current
    }

    private func resolveWorkDirectory(_ option: String?) throws -> URL {
        let path: String
        if let option {
            path = option
        } else if FileManager.default.fileExists(atPath: "/work") {
            path = "/work"
        } else {
            path = ".build/ingest"
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func ensureFreeSpace(atLeastGB minimum: Int, at url: URL) throws {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: url.path)
        guard let free = attributes[.systemFreeSize] as? Int64 else { return }
        if free < Int64(minimum) << 30 {
            throw IngestError("Only \(free >> 30) GB free at \(url.path); need \(minimum) (FLIGHTBAG_MIN_FREE_GB)")
        }
    }

    // MARK: Pipeline stages

    private func buildDatabase(cycle: DataCycle, cycleDir: URL, workDir: URL, console: Console) async throws {
        let final = cycleDir.appendingPathComponent("db/aero.sqlite")
        guard !FileManager.default.fileExists(atPath: final.path) else {
            console.info("db/aero.sqlite exists — skipping NASR/d-TPP")
            return
        }
        let temp = workDir.appendingPathComponent("aero_\(cycle.id).sqlite")
        console.info("Building aero.sqlite for \(cycle.id)…")
        let builder = try AeroDatabaseBuilder(path: temp.path)
        try builder.setMeta(cycle: cycle)
        try await NASRIngestor(workDirectory: workDir) { console.info($0) }.run(cycle: cycle, into: builder)
        try builder.buildIndexes()
        try await DTPPIngestor(workDirectory: workDir) { console.info($0) }.run(cycle: cycle, into: builder)
        try builder.vacuum()
        try publish(temp, to: final)
        console.success("db/aero.sqlite published")
    }

    private func buildTiles(scope: Scope, cycle: DataCycle, artifactsRoot: URL, workDir: URL, pipeline: TilePipeline, console: Console) async throws {
        var sources: [TilePipeline.Source] = scope.sectionals.map { .sectional(chart: $0) }
        sources += scope.ifrLowPanels.map { .enrouteLow(panel: $0) }
        sources += scope.ifrHighPanels.map { .enrouteHigh(panel: $0) }

        for source in sources {
            // Enroute editions may belong to the prior cycle (56-day cadence);
            // check both candidate homes before paying for a network probe.
            let candidates = source.isEnroute ? [cycle, cycle.previous()] : [cycle]
            if let existing = candidates.first(where: { candidate in
                FileManager.default.fileExists(
                    atPath: artifactsRoot.appendingPathComponent("\(candidate.id)/tiles/\(source.artifactFileName)").path
                )
            }) {
                console.info("tiles/\(source.artifactFileName) exists (\(existing.id)) — skipping")
                continue
            }
            let editionCycle = try await pipeline.resolveEditionCycle(for: source, requested: cycle)
            let temp = workDir.appendingPathComponent(source.artifactFileName)
            try await pipeline.run(source: source, cycle: editionCycle, output: temp.path)
            let final = artifactsRoot.appendingPathComponent("\(editionCycle.id)/tiles/\(source.artifactFileName)")
            try publish(temp, to: final)
            if source.isEnroute {
                try publish(
                    URL(fileURLWithPath: temp.path + ".expires"),
                    to: URL(fileURLWithPath: final.path + ".expires")
                )
            }
            console.success("tiles/\(source.artifactFileName) published under \(editionCycle.id)")
        }
    }

    private func buildBasemap(policy: String, cycle: DataCycle, artifactsRoot: URL, workDir: URL, pipeline: TilePipeline, console: Console) async throws {
        guard policy != "never" else { return }
        let source = TilePipeline.Source.naturalEarthBasemap
        let final = artifactsRoot.appendingPathComponent("\(cycle.id)/basemap/\(source.artifactFileName)")
        if FileManager.default.fileExists(atPath: final.path) {
            console.info("basemap exists for \(cycle.id) — skipping")
            return
        }
        if policy == "auto", basemapExists(in: artifactsRoot) {
            console.info("A basemap already exists in the artifact tree — skipping (FLIGHTBAG_BASEMAP=always to rebuild)")
            return
        }
        let temp = workDir.appendingPathComponent(source.artifactFileName)
        try await pipeline.run(source: source, cycle: cycle, output: temp.path)
        try publish(temp, to: final)
        console.success("basemap published")
    }

    private func basemapExists(in artifactsRoot: URL) -> Bool {
        let fileManager = FileManager.default
        guard let cycles = try? fileManager.contentsOfDirectory(atPath: artifactsRoot.path) else { return false }
        return cycles.contains { cycleId in
            let dir = artifactsRoot.appendingPathComponent("\(cycleId)/basemap")
            let files = (try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? []
            return files.contains { $0.hasPrefix("basemap") && $0.hasSuffix(".mbtiles") }
        }
    }

    private func buildPlates(regions: [String], cycle: DataCycle, cycleDir: URL, workDir: URL, console: Console) async throws {
        guard !regions.isEmpty else { return }
        let db = cycleDir.appendingPathComponent("db/aero.sqlite")
        guard FileManager.default.fileExists(atPath: db.path) else {
            throw IngestError("Plate bundling needs \(db.path); the database stage should have produced it")
        }
        for region in regions {
            let name = "plates_\(region)_\(cycle.id).zip"
            let final = cycleDir.appendingPathComponent("plates/\(name)")
            if FileManager.default.fileExists(atPath: final.path) {
                console.info("plates/\(name) exists — skipping")
                continue
            }
            let temp = workDir.appendingPathComponent(name)
            let bundler = PlateBundler(workDirectory: workDir) { console.info($0) }
            let count = try await bundler.run(regionId: region, databasePath: db.path, output: temp.path)
            try publish(temp, to: final)
            console.success("plates/\(name) published (\(count) plates)")
        }
    }

    private func writeManifest(artifactsRoot: URL, baseURL: URL, currentCycle: DataCycle, console: Console) throws {
        let builder = ManifestBuilder(artifactsRoot: artifactsRoot, baseURL: baseURL) { console.info($0) }
        let manifest = try builder.build(currentCycle: currentCycle)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: artifactsRoot, withIntermediateDirectories: true)
        try encoder.encode(manifest).write(to: artifactsRoot.appendingPathComponent("manifest.json"), options: .atomic)
        console.success("manifest.json: \(manifest.products.count) products (+\(manifest.nextCycleProducts.count) next-cycle)")
    }

    private func publishedManifestCycleId(artifactsRoot: URL) -> String? {
        struct Stamp: Decodable { let cycle: String }
        guard let data = try? Data(contentsOf: artifactsRoot.appendingPathComponent("manifest.json")) else { return nil }
        return (try? JSONDecoder().decode(Stamp.self, from: data))?.cycle
    }

    // MARK: Filesystem helpers

    /// Move a finished artifact into the live tree. Rename when possible; the
    /// workdir and artifact tree are separate volumes under Docker, so fall
    /// back to copy-then-rename (never exposing a half-copied file to
    /// FileMiddleware) and delete the source.
    private func publish(_ source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.removeItem(at: destination)
        do {
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            let staging = destination.appendingPathExtension("part")
            try? fileManager.removeItem(at: staging)
            try fileManager.copyItem(at: source, to: staging)
            _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
            try? fileManager.removeItem(at: source)
        }
    }

    /// Downloaded zips are cached per cycle in the workdir for resumability;
    /// drop caches from cycles older than the ones still in play.
    private func pruneWorkCaches(workDir: URL, keeping cycles: [DataCycle], console: Console) {
        let keep = Set(cycles.map(\.id))
        let chartDir = workDir.appendingPathComponent("charts")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: chartDir.path) else { return }
        for file in files {
            // Cache names end in _{cycleId}.zip / _{cycleId} (extract dirs).
            let stem = file.hasSuffix(".zip") ? String(file.dropLast(4)) : file
            guard let cycleId = stem.split(separator: "_").last.map(String.init),
                  cycleId.count == 4, cycleId.allSatisfy(\.isNumber),
                  !keep.contains(cycleId) else { continue }
            try? FileManager.default.removeItem(at: chartDir.appendingPathComponent(file))
            console.info("Pruned stale cache \(file)")
        }
    }
}
