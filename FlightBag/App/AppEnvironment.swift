import Foundation
import Observation
import FBModels
import FBProviders
import FBGDL90
import FBFISB

/// A planned route pushed onto the map from a flight's detail page.
struct ActiveMapRoute: Hashable {
    var label: String
    var coordinates: [Coordinate]
}

/// Dependency container injected at the app root. Features reach services
/// through this — never through singletons — so previews and tests can swap
/// implementations.
@MainActor
@Observable
final class AppEnvironment {
    /// nil only if the bundled database is missing/corrupt; UI shows a
    /// degraded state rather than crashing.
    let aeroDatabase: AeroDatabase?
    let weatherStore: WeatherStore
    let plateStore: PlateStore
    let filingService: any FilingService
    let advisoryStore = AdvisoryStore()
    let airspaceStore = AirspaceStore()
    let gdl90Receiver = GDL90Receiver()
    let gdl90PositionSource = GDL90PositionSource()
    let trafficStore = TrafficStore()
    let fisbRadarStore = FISBRadarStore()
    /// ADS-B preferred, CoreLocation fallback; the only position source
    /// views should touch.
    let positionSource: CompositePositionSource

    /// Route drawn on the map tab; set from a flight, cleared from the map.
    var activeMapRoute: ActiveMapRoute?
    /// One-shot tab-switch request ("Show on map"); RootTabView consumes it.
    var requestedTab: AppTab?

    init(
        weatherProvider: any WeatherProvider = AviationWeatherGovProvider(),
        filingService: any FilingService = LocalDraftFilingService()
    ) {
        self.aeroDatabase = try? AeroDatabase.open()
        self.weatherStore = WeatherStore(provider: weatherProvider)
        self.plateStore = PlateStore()
        self.filingService = filingService
        self.positionSource = CompositePositionSource(
            primary: gdl90PositionSource,
            fallback: CoreLocationPositionSource()
        )

        gdl90Receiver.onOwnship = { [gdl90PositionSource, trafficStore] report in
            gdl90PositionSource.ingest(report: report)
            // A receiver reports the ship it's installed in; suppress the echo.
            trafficStore.ownshipAddress = report.address
        }
        gdl90Receiver.onOwnshipGeoAltitude = { [gdl90PositionSource] feet in
            gdl90PositionSource.ingest(geometricAltitudeFeet: feet)
        }
        gdl90Receiver.onTraffic = { [trafficStore] report in
            trafficStore.ingest(report: report)
        }
        gdl90Receiver.onFISB = { [fisbRadarStore] product in
            if case .nexrad(let radar) = product {
                fisbRadarStore.ingest(radar)
            }
        }
        gdl90Receiver.onTick = { [weak self] _ in
            guard let self else { return }
            self.gdl90PositionSource.updateCurrency(heartbeatGPSValid: self.gdl90Receiver.gpsPositionValid)
            self.trafficStore.prune()
            self.fisbRadarStore.expire()
        }
    }
}
