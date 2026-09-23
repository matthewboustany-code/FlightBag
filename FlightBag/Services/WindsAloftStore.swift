import Foundation
import FBModels
import FBProviders

/// Winds-aloft stations with their positions resolved, cached per forecast
/// period for an hour (the FB product itself updates a few times a day).
///
/// Opening a navlog used to cost six HTTP requests plus a database lookup for
/// each of ~170 stations, every time. Modelled on `WeatherStore`, but memory
/// only: winds are worthless once stale, so there is nothing to serve offline.
actor WindsAloftStore {
    struct LocatedStation: Sendable {
        var coordinate: Coordinate
        var station: WindsAloftStation
    }

    private struct Entry {
        var stations: [LocatedStation]
        var fetchedAt: Date
    }

    static let freshFor: TimeInterval = 3_600

    private let provider: any WindsAloftProvider
    private let now: @Sendable () -> Date
    private var entries: [Int: Entry] = [:]

    init(provider: any WindsAloftProvider = AviationWeatherGovProvider(), now: @escaping @Sendable () -> Date = Date.init) {
        self.provider = provider
        self.now = now
    }

    /// Stations for a forecast period that `locate` could place. Empty when
    /// the fetch failed, which is not cached, so the next open tries again.
    func stations(
        forecastHours: Int,
        locate: @Sendable (String) async -> Coordinate?
    ) async -> [LocatedStation] {
        if let entry = entries[forecastHours], now().timeIntervalSince(entry.fetchedAt) < Self.freshFor {
            return entry.stations
        }
        guard let fetched = try? await provider.windsAloft(forecastHours: forecastHours) else { return [] }
        var located: [LocatedStation] = []
        for station in fetched {
            if let coordinate = await locate(station.identifier) {
                located.append(LocatedStation(coordinate: coordinate, station: station))
            }
        }
        if !located.isEmpty {
            entries[forecastHours] = Entry(stations: located, fetchedAt: now())
        }
        return located
    }
}
