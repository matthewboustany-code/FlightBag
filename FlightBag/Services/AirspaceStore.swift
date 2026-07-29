import Foundation
import Observation
import FBModels
import FBProviders

/// Fetches airspace volumes per map viewport and caches them — boundaries
/// change on the 28-day cycle, so cached regions stay valid for the session.
@Observable
@MainActor
final class AirspaceStore {
    private(set) var lastError: String?

    private let provider: any AirspaceProviding
    private let internationalProvider: (any AirspaceProviding)?
    private var cache: [String: [Airspace]] = [:]

    /// openAIP API key, if the user has supplied one. openAIP data is CC BY-NC
    /// and needs a key from their profile page, so worldwide airspace is
    /// opt-in rather than something FlightBag turns on for everyone.
    /// nonisolated so it can be read from the default argument below, which is
    /// evaluated outside the actor. UserDefaults is thread-safe.
    nonisolated static var openAIPKey: String? {
        UserDefaults.standard.string(forKey: "openAIPKey").flatMap { $0.isEmpty ? nil : $0 }
    }

    init(
        provider: any AirspaceProviding = FAAAirspaceProvider(),
        internationalProvider: (any AirspaceProviding)? = openAIPKey.map {
            OpenAIPAirspaceProvider(apiKey: $0)
        }
    ) {
        self.provider = provider
        self.internationalProvider = internationalProvider
    }

    /// Which provider covers a viewport.
    ///
    /// Chosen by the box's centre rather than per-airspace, because the FAA
    /// service has no data outside US airspace and openAIP is the only source
    /// that does. A viewport straddling the border gets whichever side its
    /// centre falls on — imperfect, but predictable, and better than issuing
    /// two queries and merging overlapping volumes.
    private func provider(forCentreLat lat: Double, lon: Double) -> any AirspaceProviding {
        guard let internationalProvider else { return provider }
        let isUS = Jurisdiction.forCountry(
            Self.approximateCountry(lat: lat, lon: lon)
        ).ruleSet == .faa
        return isUS ? provider : internationalProvider
    }

    /// Crude CONUS/Alaska/Hawaii box test. Only decides which airspace service
    /// to ask; a wrong answer near the border costs a fetch, not correctness.
    static func approximateCountry(lat: Double, lon: Double) -> String {
        let conus = (24.0...50.0).contains(lat) && (-125.0...(-66.0)).contains(lon)
        let alaska = (51.0...72.0).contains(lat) && (-170.0...(-129.0)).contains(lon)
        let hawaii = (18.0...23.0).contains(lat) && (-161.0...(-154.0)).contains(lon)
        return (conus || alaska || hawaii) ? "US" : "XX"
    }

    /// Airspaces intersecting the box, or nil when the fetch fails (so the
    /// map keeps showing the previous boundaries instead of blanking). The
    /// box is snapped to a half-degree grid and padded so panning nearby
    /// reuses the cache instead of refetching on every scroll tick.
    func airspaces(
        categories: Set<Airspace.Category>,
        minLat: Double, maxLat: Double, minLon: Double, maxLon: Double
    ) async -> [Airspace]? {
        guard !categories.isEmpty else { return [] }
        func snap(_ value: Double, up: Bool) -> Double {
            (up ? ceil(value * 2) : floor(value * 2)) / 2
        }
        let box = (
            minLat: snap(minLat - 0.25, up: false),
            maxLat: snap(maxLat + 0.25, up: true),
            minLon: snap(minLon - 0.25, up: false),
            maxLon: snap(maxLon + 0.25, up: true)
        )
        let key = "\(box.minLat),\(box.maxLat),\(box.minLon),\(box.maxLon)|" +
            categories.map(\.rawValue).sorted().joined(separator: ",")
        if let cached = cache[key] {
            return cached
        }
        do {
            let selected = provider(
                forCentreLat: (box.minLat + box.maxLat) / 2,
                lon: (box.minLon + box.maxLon) / 2
            )
            let result = try await selected.airspaces(
                categories: categories,
                minLat: box.minLat, minLon: box.minLon, maxLat: box.maxLat, maxLon: box.maxLon
            )
            cache[key] = result
            lastError = nil
            return result
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription.map { "Airspace: \($0)" }
                ?? "Couldn't load airspace boundaries"
            return nil
        }
    }
}
