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
    private var cache: [String: [Airspace]] = [:]

    init(provider: any AirspaceProviding = FAAAirspaceProvider()) {
        self.provider = provider
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
            let result = try await provider.airspaces(
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
