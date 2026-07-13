import Vapor

public func configure(_ app: Application) async throws {
    // Ingestion pipelines run as commands (locally during Phase 1, as
    // scheduled jobs once deployed): `swift run App ingest-nasr --cycle 2607`.
    app.asyncCommands.use(IngestNASRCommand(), as: "ingest-nasr")
    app.asyncCommands.use(IngestDTPPCommand(), as: "ingest-dtpp")
    app.asyncCommands.use(IngestTilesCommand(), as: "ingest-tiles")
    app.asyncCommands.use(BuildManifestCommand(), as: "build-manifest")

    try routes(app)
}
