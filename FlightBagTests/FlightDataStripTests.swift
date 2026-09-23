import CoreLocation
import Foundation
import Testing
import FBModels
@testable import FlightBag

@MainActor
@Suite struct FlightDataStripTests {
    private func position(speed: Double?, altitude: Double?, track: Double?) -> OwnshipPosition {
        OwnshipPosition(
            coordinate: CLLocationCoordinate2D(latitude: 30, longitude: -97),
            trackDegrees: track, groundSpeedKt: speed, altitudeFeet: altitude,
            timestamp: Date(), sourceName: "GPS"
        )
    }

    @Test func formatsInTheChosenUnits() {
        let fields = FlightDataStrip.fields(for: position(speed: 112.4, altitude: 4520, track: 7), units: .faa)
        #expect(fields.map(\.value) == ["112 kt", "4,520 ft", "007°T"])

        let metric = FlightDataStrip.fields(for: position(speed: 100, altitude: 1000, track: 270), units: .metric)
        #expect(metric[0].value.hasSuffix("km/h"))
        #expect(metric[1].value == "305 m")
    }

    @Test func unknownValuesShowAsDashes() {
        let fields = FlightDataStrip.fields(for: position(speed: nil, altitude: nil, track: nil), units: .faa)
        #expect(fields.map(\.label) == ["GS", "ALT", "TRK"])
        #expect(fields.allSatisfy { $0.value == "—" })
    }
}
