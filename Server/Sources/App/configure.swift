import Vapor

public func configure(_ app: Application) async throws {
    // ISO8601 dates on the wire (and in manifest.json) — the app's clients
    // decode with the same strategy.
    let jsonEncoder = JSONEncoder()
    jsonEncoder.dateEncodingStrategy = .iso8601
    let jsonDecoder = JSONDecoder()
    jsonDecoder.dateDecodingStrategy = .iso8601
    ContentConfiguration.global.use(encoder: jsonEncoder, for: .json)
    ContentConfiguration.global.use(decoder: jsonDecoder, for: .json)

    // Serves Public/, notably Public/artifacts/{cycle}/… download artifacts.
    // FileMiddleware supports range requests, which background URLSession
    // resume depends on.
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

    // Ingestion pipelines run as commands (locally during Phase 1, as
    // scheduled jobs once deployed): `swift run App ingest-nasr --cycle 2607`.
    app.asyncCommands.use(IngestNASRCommand(), as: "ingest-nasr")
    app.asyncCommands.use(IngestDTPPCommand(), as: "ingest-dtpp")
    app.asyncCommands.use(IngestTilesCommand(), as: "ingest-tiles")
    app.asyncCommands.use(IngestBasemapCommand(), as: "ingest-basemap")
    app.asyncCommands.use(BundlePlatesCommand(), as: "bundle-plates")
    app.asyncCommands.use(BuildManifestCommand(), as: "build-manifest")
    app.asyncCommands.use(IngestAllCommand(), as: "ingest-all")

    try routes(app)
}
