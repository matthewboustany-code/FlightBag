import Foundation
import Testing
@testable import FlightBag

@Suite struct StationCachePruningTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func dropsEntriesOlderThanThirtyDays() {
        let cache = ["KAUS": now.addingTimeInterval(-86_400), "KDAL": now.addingTimeInterval(-31 * 86_400)]
        #expect(StationCachePruning.pruned(cache, fetchedAt: { $0 }, now: now).keys.sorted() == ["KAUS"])
    }

    @Test func capsAtFiveHundredKeepingTheNewest() {
        var cache: [String: Date] = [:]
        for i in 0..<600 { cache["S\(i)"] = now.addingTimeInterval(-Double(i)) }
        let pruned = StationCachePruning.pruned(cache, fetchedAt: { $0 }, now: now)
        #expect(pruned.count == 500)
        #expect(pruned["S0"] != nil)
        #expect(pruned["S599"] == nil)
    }
}
