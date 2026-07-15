import Foundation
import CoreLocation
import Observation
import FBGDL90

/// Ownship position from the ADS-B receiver (GDL90 0x0A + 0x0B).
/// Fed by GDL90Receiver sinks; AppEnvironment does the wiring.
@MainActor
@Observable
final class GDL90PositionSource: PositionSource {
    private(set) var position: OwnshipPosition?
    /// ADS-B never blocks on permissions.
    let isDenied = false
    /// True while reports are fresh and the receiver has a GPS fix.
    /// Stored and tick-updated (not computed from Date()) so Observation
    /// fires when data stops arriving.
    private(set) var isCurrent = false
    /// Participant address from the last ownship report; the traffic
    /// store uses it to suppress the ownship echo.
    private(set) var ownshipAddress: UInt32?

    private var geometricAltitudeFeet: Int?
    private var lastReportAt: Date?
    private static let currentWithinSeconds: TimeInterval = 3

    func activate() {}  // Data-driven; nothing to request.

    func ingest(report: GDL90Message.TrafficReport) {
        ownshipAddress = report.address
        // Receivers without a GPS lock emit 0,0 / NIC 0 reports.
        guard report.nic > 0, report.latitude != 0 || report.longitude != 0 else { return }
        lastReportAt = Date()
        position = OwnshipPosition(
            coordinate: CLLocationCoordinate2D(latitude: report.latitude, longitude: report.longitude),
            trackDegrees: report.trackDegrees,
            groundSpeedKt: report.groundSpeedKt.map(Double.init),
            // Geometric (GPS) altitude beats pressure altitude for the map.
            altitudeFeet: (geometricAltitudeFeet ?? report.altitudeFeet).map(Double.init),
            timestamp: Date(),
            sourceName: "ADS-B"
        )
    }

    func ingest(geometricAltitudeFeet feet: Int) {
        geometricAltitudeFeet = feet
    }

    /// Called at 1 Hz from the receiver tick (and once on stop).
    func updateCurrency(heartbeatGPSValid: Bool, now: Date = Date()) {
        let current = heartbeatGPSValid
            && lastReportAt.map { now.timeIntervalSince($0) <= Self.currentWithinSeconds } == true
        if isCurrent != current { isCurrent = current }
    }
}

/// The app-wide position source: ADS-B when healthy, CoreLocation
/// otherwise — the fallback promised by the PositionSource doc comment.
@MainActor
@Observable
final class CompositePositionSource: PositionSource {
    private let primary: GDL90PositionSource
    private let fallback: CoreLocationPositionSource

    init(primary: GDL90PositionSource, fallback: CoreLocationPositionSource) {
        self.primary = primary
        self.fallback = fallback
    }

    var position: OwnshipPosition? {
        primary.isCurrent ? primary.position : fallback.position
    }

    /// Denied only when it actually matters: CoreLocation refused and
    /// ADS-B isn't covering for it.
    var isDenied: Bool {
        fallback.isDenied && !primary.isCurrent
    }

    func activate() {
        fallback.activate()
    }
}
