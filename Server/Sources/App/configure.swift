import Vapor
import FBProviders

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

    // Shared TTL cache backing /v1/airports/:id/weather.
    app.weatherCache = WeatherCache()

    // /v1/airports/:id/notams. Credentials come from the FAA on request
    // (NOTAMS@faa.gov) and are optional: without them the endpoint reports
    // `configured: false` and the app explains itself instead of showing an
    // empty NOTAM list.
    app.notamCache = NotamCache()
    if let clientId = Environment.get("FLIGHTBAG_NOTAM_CLIENT_ID"),
       let clientSecret = Environment.get("FLIGHTBAG_NOTAM_CLIENT_SECRET"),
       !clientId.isEmpty, !clientSecret.isEmpty {
        let environment = Environment.get("FLIGHTBAG_NOTAM_ENV").flatMap(NMSEnvironment.init(rawValue:)) ?? .production
        app.notamProvider = FAANotamProvider(
            credentials: NMSCredentials(clientId: clientId, clientSecret: clientSecret),
            environment: environment
        )
        app.logger.info("FAA NMS NOTAM provider configured (\(environment.rawValue))")
    } else {
        app.logger.notice("No FAA NMS credentials — /v1/airports/:id/notams will report configured: false")
    }

    // Ingestion pipelines run as commands (locally during Phase 1, as
    // scheduled jobs once deployed): `swift run App ingest-nasr --cycle 2607`.
    app.asyncCommands.use(IngestNASRCommand(), as: "ingest-nasr")
    app.asyncCommands.use(IngestOurAirportsCommand(), as: "ingest-ourairports")
    app.asyncCommands.use(IngestDTPPCommand(), as: "ingest-dtpp")
    app.asyncCommands.use(IngestCIFPCommand(), as: "ingest-cifp")
    app.asyncCommands.use(IngestTilesCommand(), as: "ingest-tiles")
    app.asyncCommands.use(IngestBasemapCommand(), as: "ingest-basemap")
    app.asyncCommands.use(BundlePlatesCommand(), as: "bundle-plates")
    app.asyncCommands.use(BuildManifestCommand(), as: "build-manifest")
    app.asyncCommands.use(IngestAllCommand(), as: "ingest-all")

    try routes(app)
}
