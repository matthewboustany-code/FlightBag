import CoreLocation
import Foundation
import Testing
import FBGDL90
@testable import FlightBag

@MainActor
@Suite struct TrafficAnnotationTests {
    private func report(lat: Double = 30.2, altitude: Int = 4500, track: Double = 90, callsign: String = "N771TC") -> GDL90Message.TrafficReport {
        GDL90Message.TrafficReport(
            address: 0xC00001, latitude: lat, longitude: -97.6, altitudeFeet: altitude,
            airborne: true, trackDegrees: track, groundSpeedKt: 120, verticalVelocityFpm: 0, callsign: callsign
        )
    }

    @Test func movementAloneDoesNotAskForARedraw() {
        let annotation = TrafficAnnotation(address: 0xC00001)
        annotation.update(from: report(), ownshipAltitudeFt: 3000)
        let version = annotation.reportVersion
        // Position and track move the view and rotate the chevron; neither
        // changes what the data block says.
        annotation.update(from: report(lat: 30.21, track: 95), ownshipAltitudeFt: 3000)
        #expect(annotation.reportVersion == version)
        #expect(annotation.coordinate.latitude == 30.21)
        #expect(annotation.trackDegrees == 95)
    }

    @Test func dataBlockChangesBumpTheVersion() {
        let annotation = TrafficAnnotation(address: 0xC00001)
        annotation.update(from: report(), ownshipAltitudeFt: 3000)
        let version = annotation.reportVersion
        annotation.update(from: report(altitude: 4600), ownshipAltitudeFt: 3000)
        #expect(annotation.reportVersion == version + 1)
        annotation.update(from: report(altitude: 4600), ownshipAltitudeFt: 3100)
        #expect(annotation.reportVersion == version + 2)
    }
}
