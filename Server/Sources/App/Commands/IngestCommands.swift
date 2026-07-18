import Vapor
import FBModels

// Ingestion pipelines. Run locally during Phase 1
// (`swift run App ingest-nasr`), as scheduled jobs once deployed.
// `build-manifest` (artifact publishing) arrives with the CDN in Phase 2.

struct IngestSignature: CommandSignature {
    @Option(name: "cycle", help: "AIRAC cycle id, e.g. 2607. Defaults to the current cycle.")
    var cycle: String?

    @Option(name: "workdir", help: "Directory for downloads and intermediate files. Defaults to .build/ingest")
    var workdir: String?

    @Option(name: "output", help: "Path of the aero.sqlite to produce. Defaults to <workdir>/aero.sqlite")
    var output: String?

    init() {}
}

extension IngestSignature {
    func resolveCycle() throws -> DataCycle {
        guard let cycle else { return DataCycle.current() }
        guard let parsed = DataCycle(id: cycle) else {
            throw Abort(.badRequest, reason: "\(cycle) is not a valid AIRAC cycle identifier")
        }
        return parsed
    }

    func resolveWorkDirectory() throws -> URL {
        let url = URL(fileURLWithPath: workdir ?? ".build/ingest", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func resolveOutput() throws -> String {
        if let output { return output }
        return try resolveWorkDirectory().appendingPathComponent("aero.sqlite").path
    }
}

struct IngestNASRCommand: AsyncCommand {
    typealias Signature = IngestSignature

    var help: String {
        "Download the FAA NASR CSV bundles and build the aero.sqlite airport/nav database"
    }

    func run(using context: CommandContext, signature: IngestSignature) async throws {
        let cycle = try signature.resolveCycle()
        let workDir = try signature.resolveWorkDirectory()
        let output = try signature.resolveOutput()
        let console = context.console

        console.info("NASR ingestion for cycle \(cycle.id) → \(output)")
        let builder = try AeroDatabaseBuilder(path: output)
        try builder.setMeta(cycle: cycle)

        let ingestor = NASRIngestor(workDirectory: workDir) { console.info($0) }
        try await ingestor.run(cycle: cycle, into: builder)
        try builder.buildIndexes()
        try builder.vacuum()
        console.success("aero.sqlite written to \(output)")
    }
}

struct IngestDTPPCommand: AsyncCommand {
    typealias Signature = IngestSignature

    var help: String {
        "Download the FAA d-TPP metafile and add plate metadata to an existing aero.sqlite"
    }

    func run(using context: CommandContext, signature: IngestSignature) async throws {
        let cycle = try signature.resolveCycle()
        let workDir = try signature.resolveWorkDirectory()
        let output = try signature.resolveOutput()
        let console = context.console

        guard FileManager.default.fileExists(atPath: output) else {
            throw Abort(.badRequest, reason: "\(output) does not exist — run ingest-nasr first")
        }

        console.info("d-TPP ingestion for cycle \(cycle.id) → \(output)")
        let builder = try AeroDatabaseBuilder(existingPath: output)
        let ingestor = DTPPIngestor(workDirectory: workDir) { console.info($0) }
        try await ingestor.run(cycle: cycle, into: builder)
        try builder.vacuum()
        console.success("Plate metadata added to \(output)")
    }
}

struct IngestCIFPCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "cycle", help: "AIRAC cycle id, e.g. 2607. Defaults to the current cycle.")
        var cycle: String?

        @Option(name: "workdir", help: "Directory for downloads and intermediate files. Defaults to .build/ingest")
        var workdir: String?

        @Option(name: "output", help: "Path of the aero.sqlite to add procedures to. Defaults to <workdir>/aero.sqlite")
        var output: String?

        @Option(name: "input", help: "Path to a manually downloaded FAACIFP18 (skips the FAA download)")
        var input: String?

        init() {}
    }

    var help: String {
        "Download the FAA CIFP (ARINC 424) and add SID/STAR geometry to an existing aero.sqlite"
    }

    func run(using context: CommandContext, signature: Signature) async throws {
        let cycle: DataCycle
        if let id = signature.cycle {
            guard let parsed = DataCycle(id: id) else {
                throw Abort(.badRequest, reason: "\(id) is not a valid AIRAC cycle identifier")
            }
            cycle = parsed
        } else {
            cycle = DataCycle.current()
        }
        let workDir = URL(fileURLWithPath: signature.workdir ?? ".build/ingest", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let output = signature.output ?? workDir.appendingPathComponent("aero.sqlite").path
        guard FileManager.default.fileExists(atPath: output) else {
            throw Abort(.badRequest, reason: "\(output) does not exist — run ingest-nasr first")
        }

        let console = context.console
        console.info("CIFP ingestion for cycle \(cycle.id) → \(output)")
        let builder = try AeroDatabaseBuilder(existingPath: output)
        let ingestor = CIFPIngestor(workDirectory: workDir) { console.info($0) }
        try await ingestor.run(cycle: cycle, into: builder, input: signature.input)
        try builder.vacuum()
        console.success("SID/STAR procedures added to \(output)")
    }
}

struct IngestTilesCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "set", help: "Chart set: vfr (default), ifr-low, ifr-high")
        var set: String?

        @Option(name: "chart", help: "FAA sectional name for --set vfr, e.g. San_Antonio")
        var chart: String?

        @Option(name: "panel", help: "Enroute panel number for --set ifr-low (1-36) / ifr-high (1-12)")
        var panel: Int?

        @Option(name: "cycle", help: "AIRAC cycle id, e.g. 2607. Defaults to the current cycle.")
        var cycle: String?

        @Option(name: "workdir", help: "Directory for downloads and intermediate files. Defaults to .build/ingest")
        var workdir: String?

        @Option(name: "output", help: "MBTiles output path. Defaults to <workdir>/<artifact-name>.mbtiles")
        var output: String?

        @Option(name: "gdal-bin", help: "Directory containing GDAL binaries. Defaults to $PATH lookup.")
        var gdalBin: String?

        init() {}
    }

    var help: String {
        "Convert an FAA chart (VFR sectional or IFR enroute panel) into Web-Mercator MBTiles"
    }

    func run(using context: CommandContext, signature: Signature) async throws {
        let source: TilePipeline.Source
        switch signature.set ?? "vfr" {
        case "vfr":
            guard let chart = signature.chart else {
                throw Abort(.badRequest, reason: "--chart is required for --set vfr (e.g. --chart San_Antonio)")
            }
            source = .sectional(chart: chart)
        case "ifr-low":
            guard let panel = signature.panel, (1...36).contains(panel) else {
                throw Abort(.badRequest, reason: "--panel 1-36 is required for --set ifr-low")
            }
            source = .enrouteLow(panel: panel)
        case "ifr-high":
            guard let panel = signature.panel, (1...12).contains(panel) else {
                throw Abort(.badRequest, reason: "--panel 1-12 is required for --set ifr-high")
            }
            source = .enrouteHigh(panel: panel)
        default:
            throw Abort(.badRequest, reason: "--set must be vfr, ifr-low, or ifr-high")
        }

        let requested: DataCycle
        if let id = signature.cycle {
            guard let parsed = DataCycle(id: id) else {
                throw Abort(.badRequest, reason: "\(id) is not a valid AIRAC cycle identifier")
            }
            requested = parsed
        } else {
            requested = DataCycle.current()
        }
        let workDir = URL(fileURLWithPath: signature.workdir ?? ".build/ingest", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let console = context.console
        let pipeline = TilePipeline(
            workDirectory: workDir,
            gdalBinDirectory: signature.gdalBin
        ) { console.info($0) }

        // Enroute editions publish every other cycle; walk back if needed so
        // the artifact is attributed to the cycle its edition belongs to.
        let cycle = try await pipeline.resolveEditionCycle(for: source, requested: requested)
        if cycle != requested {
            console.warning("No \(source.cacheStem) edition for cycle \(requested.id); using edition cycle \(cycle.id)")
        }
        let output = signature.output ?? workDir.appendingPathComponent(source.artifactFileName).path

        console.info("Tile pipeline: \(source.artifactFileName), cycle \(cycle.id)")
        try await pipeline.run(source: source, cycle: cycle, output: output)
        console.success("Done: \(output)")
        console.info("Publish under Public/artifacts/\(cycle.id)/tiles/ (with any .expires sidecar), then re-run build-manifest.")
    }
}

struct IngestBasemapCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "cycle", help: "AIRAC cycle whose artifact directory receives the basemap. Defaults to the current cycle.")
        var cycle: String?

        @Option(name: "workdir", help: "Directory for downloads and intermediate files. Defaults to .build/ingest")
        var workdir: String?

        @Option(name: "output", help: "MBTiles output path. Defaults to <workdir>/basemap_natural_earth.mbtiles")
        var output: String?

        @Option(name: "gdal-bin", help: "Directory containing GDAL binaries. Defaults to $PATH lookup.")
        var gdalBin: String?

        init() {}
    }

    var help: String {
        "Build the offline shaded-relief basemap MBTiles from Natural Earth II (public domain)"
    }

    func run(using context: CommandContext, signature: Signature) async throws {
        let cycle: DataCycle
        if let id = signature.cycle {
            guard let parsed = DataCycle(id: id) else {
                throw Abort(.badRequest, reason: "\(id) is not a valid AIRAC cycle identifier")
            }
            cycle = parsed
        } else {
            cycle = DataCycle.current()
        }
        let workDir = URL(fileURLWithPath: signature.workdir ?? ".build/ingest", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let source = TilePipeline.Source.naturalEarthBasemap
        let output = signature.output ?? workDir.appendingPathComponent(source.artifactFileName).path

        let console = context.console
        console.info("Basemap pipeline: Natural Earth II shaded relief")
        let pipeline = TilePipeline(
            workDirectory: workDir,
            gdalBinDirectory: signature.gdalBin
        ) { console.info($0) }
        try await pipeline.run(source: source, cycle: cycle, output: output)
        console.success("Done: \(output)")
        console.info("Publish under Public/artifacts/\(cycle.id)/basemap/, then re-run build-manifest.")
    }
}

struct BundlePlatesCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "region", help: "Region id, e.g. US-TX")
        var region: String?

        @Option(name: "db", help: "Path to an aero.sqlite with d-TPP plate data")
        var db: String?

        @Option(name: "workdir", help: "Directory for downloads and staging. Defaults to .build/ingest")
        var workdir: String?

        @Option(name: "output", help: "Zip output path. Defaults to <workdir>/plates_<region>_<cycle>.zip")
        var output: String?

        init() {}
    }

    var help: String {
        "Bundle every terminal-procedure PDF for a region into one downloadable zip"
    }

    func run(using context: CommandContext, signature: Signature) async throws {
        guard let region = signature.region else {
            throw Abort(.badRequest, reason: "--region is required (e.g. --region US-TX)")
        }
        guard let db = signature.db, FileManager.default.fileExists(atPath: db) else {
            throw Abort(.badRequest, reason: "--db must point at an existing aero.sqlite (run ingest-nasr + ingest-dtpp first)")
        }
        let workDir = URL(fileURLWithPath: signature.workdir ?? ".build/ingest", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let console = context.console
        let cycle = try PlateBundler.databaseCycle(databasePath: db)
        let output = signature.output ?? workDir.appendingPathComponent("plates_\(region)_\(cycle).zip").path

        let bundler = PlateBundler(workDirectory: workDir) { console.info($0) }
        let count = try await bundler.run(regionId: region, databasePath: db, output: output)
        console.success("\(count) plates → \(output)")
        console.info("Publish under Public/artifacts/\(cycle)/plates/, then re-run build-manifest.")
    }
}

struct BuildManifestCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "cycle", help: "AIRAC cycle id, e.g. 2607. Defaults to the current cycle.")
        var cycle: String?

        @Option(name: "artifacts", help: "Artifact tree root. Defaults to Public/artifacts")
        var artifacts: String?

        @Option(name: "base-url", help: "Absolute URL prefix for product download URLs. Defaults to http://127.0.0.1:8080")
        var baseURL: String?

        init() {}
    }

    var help: String {
        "Scan the artifact tree and write Public/artifacts/manifest.json for /v1/manifest"
    }

    func run(using context: CommandContext, signature: Signature) async throws {
        let cycle: DataCycle
        if let id = signature.cycle {
            guard let parsed = DataCycle(id: id) else {
                throw Abort(.badRequest, reason: "\(id) is not a valid AIRAC cycle identifier")
            }
            cycle = parsed
        } else {
            cycle = DataCycle.current()
        }
        guard let baseURL = URL(string: signature.baseURL ?? "http://127.0.0.1:8080") else {
            throw Abort(.badRequest, reason: "--base-url is not a valid URL")
        }
        let artifactsRoot = URL(
            fileURLWithPath: signature.artifacts ?? context.application.directory.publicDirectory + "artifacts",
            isDirectory: true
        )

        let console = context.console
        console.info("Building manifest for cycle \(cycle.id) from \(artifactsRoot.path)")
        let builder = ManifestBuilder(artifactsRoot: artifactsRoot, baseURL: baseURL) { console.info($0) }
        let manifest = try builder.build(currentCycle: cycle)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let output = artifactsRoot.appendingPathComponent("manifest.json")
        try FileManager.default.createDirectory(at: artifactsRoot, withIntermediateDirectories: true)
        try encoder.encode(manifest).write(to: output, options: .atomic)
        console.success("\(manifest.products.count) products (+\(manifest.nextCycleProducts.count) next-cycle) → \(output.path)")
    }
}
