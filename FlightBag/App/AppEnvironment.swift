import Foundation
import Observation
import FBProviders

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
