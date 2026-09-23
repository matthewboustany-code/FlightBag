import CoreLocation
import Foundation
import Testing
import FBGDL90
@testable import FlightBag

@MainActor
@Suite struct TrafficThreatTests {
    private let ownship = OwnshipPosition(
        coordinate: CLLocationCoordinate2D(latitude: 30.0, longitude: -97.0),
        trackDegrees: 0, groundSpeedKt: 100, altitudeFeet: 3000, timestamp: Date(), sourceName: "Test"
    )

    /// A target `northNM` ahead and `eastNM` right of the test ownship.
    private func target(_ address: UInt32, northNM: Double, eastNM: Double = 0, altitude: Int? = 3300,
                        track: Double = 180, speed: Int? = 100, airborne: Bool = true, alert: Bool = false,
                        callsign: String = "N52TA") -> GDL90Message.TrafficReport {
        GDL90Message.TrafficReport(
            alert: alert, address: address,
            latitude: 30.0 + northNM / 60, longitude: -97.0 + eastNM / (60 * cos(30.0 * .pi / 180)),
            altitudeFeet: altitude, airborne: airborne, trackDegrees: track, groundSpeedKt: speed,
            callsign: callsign
        )
    }

    private func store(_ reports: GDL90Message.TrafficReport...) -> TrafficStore {
        let store = TrafficStore()
        for report in reports { store.ingest(report: report) }
        return store
    }

    @Test func headOnTargetInsideTheBoxIsAThreat() throws {
        let threat = try #require(store(target(1, northNM: 1)).nearestThreat(ownship: ownship))
        #expect(threat.clockPosition == 12)
        #expect(threat.relativeAltitudeFt == 300)
        #expect(abs(threat.distanceNM - 1) < 0.02)
        #expect(!threat.receiverAlert)
    }

    @Test func clockPositionIsRelativeToTrack() throws {
        var heading90 = ownship
        heading90.trackDegrees = 90
        // Due north of an eastbound ownship is off the left wing, closing.
        let threat = try #require(store(target(1, northNM: 1, track: 180))
            .nearestThreat(ownship: heading90))
        #expect(threat.clockPosition == 9)
    }

    @Test func outsideTheBoxOrDivergingIsNot() {
        #expect(store(target(1, northNM: 2.5)).nearestThreat(ownship: ownship) == nil)          // too far
        #expect(store(target(1, northNM: 1, altitude: 4200)).nearestThreat(ownship: ownship) == nil)  // 1,200 ft above
        #expect(store(target(1, northNM: 1, track: 0, speed: 180)).nearestThreat(ownship: ownship) == nil)  // pulling away
        #expect(store(target(1, northNM: 1, airborne: false)).nearestThreat(ownship: ownship) == nil)  // on the ground
        #expect(store(target(1, northNM: 1, altitude: nil)).nearestThreat(ownship: ownship) == nil)   // unknown altitude
    }

    @Test func receiverAlertWinsEvenOutsideTheBox() throws {
        let threat = try #require(store(
            target(1, northNM: 0.8, callsign: "NEAR"),
            target(2, northNM: 4, track: 0, speed: 180, alert: true, callsign: "FLAGGED")
        ).nearestThreat(ownship: ownship))
        #expect(threat.callsign == "FLAGGED")
        #expect(threat.receiverAlert)
    }

    @Test func nearestOfSeveral() throws {
        let threat = try #require(store(
            target(1, northNM: 1.6, callsign: "FAR"),
            target(2, northNM: 0.7, callsign: "CLOSE")
        ).nearestThreat(ownship: ownship))
        #expect(threat.callsign == "CLOSE")
    }

    @Test func bannerReadsLikeAnAdvisory() {
        let threat = TrafficThreat(address: 1, callsign: "N52TA", distanceNM: 1.04, relativeAltitudeFt: -300,
                                   clockPosition: 2, receiverAlert: false)
        #expect(TrafficThreatBanner.detail(for: threat) == "N52TA · 2 o'clock · −300 ft · 1.0 NM")
    }
}
