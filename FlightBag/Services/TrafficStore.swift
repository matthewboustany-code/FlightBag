import Foundation
import Observation
import FBGDL90

/// One tracked traffic target: the decoded report plus when it was last
/// heard, for aging.
struct TrafficTarget: Identifiable, Sendable {
    let report: GDL90Message.TrafficReport
    var lastSeen: Date

    var id: UInt32 { report.address }
}

/// Live ADS-B/TIS-B traffic, keyed by participant address. Fed by the
/// GDL90Receiver sink; the map reads `targets`.
@MainActor
@Observable
final class TrafficStore {
    private(set) var targets: [UInt32: TrafficTarget] = [:]
    /// Bumped only when the set of targets changes (add/remove), so the
    /// map rebuilds annotations on membership change but mutates position
    /// in place on every update.
    private(set) var membershipVersion = 0

    /// The ownship's own participant address, so we never draw it as
    /// traffic (a receiver reports the ship it's installed in).
    var ownshipAddress: UInt32?

    private static let ageOutSeconds: TimeInterval = 30

    func ingest(report: GDL90Message.TrafficReport, now: Date = Date()) {
        guard report.address != ownshipAddress else { return }
        // Targets without a usable position can't be drawn.
        guard report.latitude != 0 || report.longitude != 0 else { return }
        if targets[report.address] == nil { membershipVersion += 1 }
        targets[report.address] = TrafficTarget(report: report, lastSeen: now)
    }

    /// Drop targets not heard within the age-out window. Call on the 1 Hz
    /// receiver tick.
    func prune(now: Date = Date()) {
        let stale = targets.filter { now.timeIntervalSince($0.value.lastSeen) > Self.ageOutSeconds }
        guard !stale.isEmpty else { return }
        for key in stale.keys { targets[key] = nil }
        membershipVersion += 1
    }

    func clear() {
        guard !targets.isEmpty else { return }
        targets.removeAll()
        membershipVersion += 1
    }
}
