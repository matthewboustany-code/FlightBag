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

struct BuildManifestCommand: AsyncCommand {
    typealias Signature = IngestSignature

    var help: String {
        "Emit the versioned download manifest for produced artifacts"
    }

    func run(using context: CommandContext, signature: IngestSignature) async throws {
        let cycle = try signature.resolveCycle()
        context.console.info("Building manifest for cycle \(cycle.id)")
        context.console.warning("Arrives with object-storage publishing in Phase 2.")
    }
}
