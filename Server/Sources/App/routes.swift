import Vapor
import FBModels
import FBProviders

func routes(_ app: Application) throws {
    app.get { _ in
        "FlightBag API"
    }

    let v1 = app.grouped("v1")

    // Offline-download manifest. Products fill in once the ingestion
    // pipelines publish artifacts to object storage.
    v1.get("manifest") { _ async throws -> DownloadManifest in
        DownloadManifest(
            generatedAt: Date(),
            cycle: DataCycle.current().id,
            products: []
        )
    }

    // Normalized METAR/TAF for one airport. The backend is a cache/etiquette
    // layer over aviationweather.gov; the app also keeps a direct path for
    // in-flight fallback.
    v1.get("airports", ":id", "weather") { req async throws -> AirportWeatherResponse in
        guard let id = req.parameters.get("id") else {
            throw Abort(.badRequest)
        }
        let station = ICAOIdentifier(id)
        let provider = AviationWeatherGovProvider()
        async let metar = provider.metar(for: station)
        async let taf = provider.taf(for: station)
        return AirportWeatherResponse(station: station, metar: try await metar, taf: try await taf)
    }
}

struct AirportWeatherResponse: Content {
    let station: ICAOIdentifier
    let metar: Metar?
    let taf: Taf?
}

extension DownloadManifest: Content {}
