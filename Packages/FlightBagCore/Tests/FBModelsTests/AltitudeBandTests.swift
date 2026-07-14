import Foundation
import Testing
@testable import FBModels

@Suite struct AltitudeBandTests {
    @Test func parsesPublishedAltitudeTexts() {
        #expect(AltitudeBand.feet(fromText: "SFC") == 0)
        #expect(AltitudeBand.feet(fromText: "0 FT") == 0)
        #expect(AltitudeBand.feet(fromText: "4999 FT") == 4999)
        #expect(AltitudeBand.feet(fromText: "4,800 ft MSL") == 4800)
        #expect(AltitudeBand.feet(fromText: "FL 180") == 18000)
        #expect(AltitudeBand.feet(fromText: "180 FL") == 18000)
        // G-AIRMET values arrive in hundreds of feet.
        #expect(AltitudeBand.feet(fromText: "240", hundredsOfFeet: true) == 24000)
        #expect(AltitudeBand.feet(fromText: "SFC", hundredsOfFeet: true) == 0)
        // Unbounded or unknown → nil.
        #expect(AltitudeBand.feet(fromText: "UNL") == nil)
        #expect(AltitudeBand.feet(fromText: "FZL", hundredsOfFeet: true) == nil)
        #expect(AltitudeBand.feet(fromText: nil) == nil)
        #expect(AltitudeBand.feet(fromText: "—") == nil)
    }

    @Test func bandContainmentTreatsMissingBoundsAsInclusive() {
        let bounded = AltitudeBand(lowFt: 2000, highFt: 8000)
        #expect(!bounded.contains(altitudeFt: 1999))
        #expect(bounded.contains(altitudeFt: 2000))
        #expect(bounded.contains(altitudeFt: 8000))
        #expect(!bounded.contains(altitudeFt: 8001))

        // No published floor: applies from the surface up to its ceiling.
        let noFloor = AltitudeBand(lowFt: nil, highFt: 36000)
        #expect(noFloor.contains(altitudeFt: 0))
        #expect(!noFloor.contains(altitudeFt: 40000))

        // Nothing published: never filtered out (safety bias).
        let unknown = AltitudeBand()
        #expect(unknown.contains(altitudeFt: 4500))
    }

    @Test func advisoryBandsComeFromTheirPublishedFields() {
        let sigmet = WeatherAdvisory(
            id: "s", kind: .sigmet, hazard: "CONVECTIVE",
            validFrom: .now, validTo: .now.addingTimeInterval(3600),
            altitudeLowFt: nil, altitudeHiFt: 36000
        )
        #expect(sigmet.altitudeBand == AltitudeBand(lowFt: nil, highFt: 36000))

        let airmet = GraphicalAirmet(
            id: "g", product: .tango, hazard: "TURB-HI",
            validTime: .now, expireTime: .now.addingTimeInterval(3600),
            forecastHour: 3, top: "390", base: "240"
        )
        #expect(airmet.altitudeBand == AltitudeBand(lowFt: 24000, highFt: 39000))
        #expect(!airmet.altitudeBand.contains(altitudeFt: 6500))

        let area = TemporaryFlightRestriction.Area(floorText: "0 FT", ceilingText: "4999 FT", polygon: [])
        #expect(area.altitudeBand.contains(altitudeFt: 3000))
        #expect(!area.altitudeBand.contains(altitudeFt: 6500))
    }
}
