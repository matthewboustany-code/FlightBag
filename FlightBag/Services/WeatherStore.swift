import Foundation
import FBModels
import FBProviders
import FBFISB

/// Stands in for the live provider when simulating no connectivity, so
/// the cached/FIS-B paths can be driven in the simulator.
struct OfflineWeatherProvider: WeatherProvider {
    struct Offline: Error {}

    func metar(for station: ICAOIdentifier) async throws -> Metar? { throw Offline() }
    func metars(for stations: [ICAOIdentifier]) async throws -> [Metar] { throw Offline() }
    func taf(for station: ICAOIdentifier) async throws -> Taf? { throw Offline() }
}

/// Fetches METAR/TAF through the injected provider and keeps the last good
/// result per station on disk, so weather remains visible (age-stamped)
/// with no connectivity. In flight, FIS-B uplink fills the same cache.
actor WeatherStore {
    /// Where a cached report came from. Optional for Codable compatibility
    /// with caches written before FIS-B existed.
    enum Source: String, Codable, Sendable {
        case internet
        case fisb
    }

    struct StationWeather: Codable, Sendable {
        var metar: Metar?
        var taf: Taf?
        var fetchedAt: Date
        var source: Source?
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
            let fresh = StationWeather(metar: try await metar, taf: try await taf, fetchedAt: Date(), source: .internet)
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

    /// Folds FIS-B text reports into the same cache the airport screens
    /// read. Only the raw text is available over the uplink, so decoded
    /// fields (and the flight-category badge) stay empty until an internet
    /// fetch replaces them.
    func ingestFISB(reports: [FISBTextReport], receivedAt: Date = Date()) {
        var touched = false
        for report in reports {
            let station = report.station.trimmingCharacters(in: .whitespaces).uppercased()
            guard !station.isEmpty else { continue }
            var entry = cache[station] ?? StationWeather(metar: nil, taf: nil, fetchedAt: receivedAt)
            switch report.kind {
            case .metar, .speci:
                entry.metar = Metar(station: ICAOIdentifier(station), raw: report.text)
            case .taf, .tafAmendment:
                entry.taf = Taf(station: ICAOIdentifier(station), raw: report.text)
            case .pirep, .windsAloft, .other:
                continue  // Not surfaced by the airport weather screen.
            }
            // The uplink rebroadcasts on a loop; never age-regress an entry.
            guard receivedAt >= entry.fetchedAt else { continue }
            entry.fetchedAt = receivedAt
            entry.source = .fisb
            cache[station] = entry
            touched = true
        }
        if touched { persist() }
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }
}
