import Foundation
import FBModels
import FBProviders

/// Fetches METAR/TAF through the injected provider and keeps the last good
/// result per station on disk, so weather remains visible (age-stamped)
/// with no connectivity.
actor WeatherStore {
    struct StationWeather: Codable, Sendable {
        var metar: Metar?
        var taf: Taf?
        var fetchedAt: Date
    }

    private let provider: any WeatherProvider
    private var cache: [String: StationWeather] = [:]
    private let cacheURL: URL

    init(provider: any WeatherProvider) {
        self.provider = provider
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        cacheURL = support.appendingPathComponent("FlightBag/weather-cache.json")
        if let data = try? Data(contentsOf: cacheURL),
           let stored = try? JSONDecoder().decode([String: StationWeather].self, from: data) {
            cache = stored
        }
    }

    /// Live weather when reachable; otherwise the cached copy. `isStale` is
    /// true when the returned data came from cache.
    func weather(for station: ICAOIdentifier) async -> (weather: StationWeather?, isStale: Bool) {
        do {
            async let metar = provider.metar(for: station)
            async let taf = provider.taf(for: station)
            let fresh = StationWeather(metar: try await metar, taf: try await taf, fetchedAt: Date())
            if fresh.metar != nil || fresh.taf != nil {
                cache[station.rawValue] = fresh
                persist()
                return (fresh, false)
            }
            // Station reports nothing (no weather sensor) — don't overwrite cache.
            return (cache[station.rawValue], cache[station.rawValue] != nil)
        } catch {
            return (cache[station.rawValue], cache[station.rawValue] != nil)
        }
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }
}
