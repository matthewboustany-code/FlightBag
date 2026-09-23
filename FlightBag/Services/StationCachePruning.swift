import Foundation

/// Bounds the on-disk per-station caches (`WeatherStore`, `NotamStore`).
/// Both rewrite the whole file on every change and never dropped a station,
/// so every airport ever looked at, or heard over FIS-B, stayed forever.
enum StationCachePruning {
    static let maxAge: TimeInterval = 30 * 86_400
    static let maxStations = 500

    /// Entries fetched within `maxAge`, keeping the most recent `maxStations`.
    static func pruned<Entry>(
        _ cache: [String: Entry],
        fetchedAt: (Entry) -> Date,
        now: Date = Date()
    ) -> [String: Entry] {
        let fresh = cache.filter { now.timeIntervalSince(fetchedAt($0.value)) <= maxAge }
        guard fresh.count > maxStations else { return fresh }
        let kept = fresh.sorted { fetchedAt($0.value) > fetchedAt($1.value) }.prefix(maxStations)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }
}
