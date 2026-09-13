import CoreLocation
import Foundation
import Observation
import FBGDL90
import FBModels
import FBFlightPlan

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

// MARK: - Proximity

/// The one traffic target worth interrupting the pilot for.
struct TrafficThreat: Equatable, Sendable {
    var address: UInt32
    var callsign: String
    var distanceNM: Double
    /// Target minus ownship; nil when either altitude is unknown.
    var relativeAltitudeFt: Int?
    /// 1–12, relative to ownship track (north when there is no track).
    var clockPosition: Int
    /// The receiver itself flagged this target (GDL90 traffic alert status).
    var receiverAlert: Bool
}

extension TrafficStore {
    static let threatLateralNM = 2.0
    static let threatVerticalFt = 1_000

    /// The nearest target within 2 NM laterally and ±1,000 ft that is
    /// closing, or any target the receiver has flagged as an alert — those
    /// first, since the receiver may know something (its own collision logic)
    /// that this geometry doesn't. Airborne targets only.
    func nearestThreat(ownship: OwnshipPosition?) -> TrafficThreat? {
        guard let ownship else { return nil }
        let own = Coordinate(latitude: ownship.coordinate.latitude, longitude: ownship.coordinate.longitude)
        var candidates: [TrafficThreat] = []
        for target in targets.values where target.report.airborne {
            let report = target.report
            let position = Coordinate(latitude: report.latitude, longitude: report.longitude)
            let distance = NavMath.distanceNM(from: own, to: position)
            let relativeAltitude: Int? = if let altitude = report.altitudeFeet, let ownAltitude = ownship.altitudeFeet {
                altitude - Int(ownAltitude.rounded())
            } else {
                nil
            }
            let geometric = distance <= Self.threatLateralNM
                && relativeAltitude.map { abs($0) <= Self.threatVerticalFt } == true
                && Self.isClosing(ownship: ownship, target: report)
            guard geometric || report.alert else { continue }

            let bearing = NavMath.initialBearing(from: own, to: position)
            let relative = (bearing - (ownship.trackDegrees ?? 0) + 720).truncatingRemainder(dividingBy: 360)
            let clock = Int((relative / 30).rounded()) % 12
            candidates.append(TrafficThreat(
                address: report.address,
                callsign: report.callsign.trimmingCharacters(in: .whitespaces),
                distanceNM: distance,
                relativeAltitudeFt: relativeAltitude,
                clockPosition: clock == 0 ? 12 : clock,
                receiverAlert: report.alert
            ))
        }
        return candidates.min { lhs, rhs in
            if lhs.receiverAlert != rhs.receiverAlert { return lhs.receiverAlert }
            return lhs.distanceNM < rhs.distanceNM
        }
    }

    /// Whether range is decreasing, from both ground velocities in a local
    /// flat frame (fine at 2 NM). Unknown speed or track counts as stopped.
    nonisolated static func isClosing(ownship: OwnshipPosition, target: GDL90Message.TrafficReport) -> Bool {
        let cosLat = cos(ownship.coordinate.latitude * .pi / 180)
        let dx = (target.longitude - ownship.coordinate.longitude) * 60 * cosLat
        let dy = (target.latitude - ownship.coordinate.latitude) * 60
        func velocity(speed: Double?, track: Double?) -> (Double, Double) {
            guard let speed, let track else { return (0, 0) }
            let radians = track * .pi / 180
            return (speed * sin(radians), speed * cos(radians))
        }
        let own = velocity(speed: ownship.groundSpeedKt, track: ownship.trackDegrees)
        let other = velocity(speed: target.groundSpeedKt.map(Double.init), track: target.trackDegrees)
        return dx * (other.0 - own.0) + dy * (other.1 - own.1) < 0
    }
}
