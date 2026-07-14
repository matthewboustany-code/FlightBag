import Foundation
import Observation
import FBModels
import FBProviders

/// A planned route pushed onto the map from a flight's detail page.
struct ActiveMapRoute: Hashable {
    var label: String
    var coordinates: [Coordinate]
}

/// Dependency container injected at the app root. Features reach services
/// through this — never through singletons — so previews and tests can swap
/// implementations.
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
    }
}
