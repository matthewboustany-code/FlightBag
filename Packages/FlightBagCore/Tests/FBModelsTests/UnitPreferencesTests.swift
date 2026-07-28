import Foundation
import Testing
@testable import FBModels

@Suite struct UnitPreferencesTests {
    // MARK: Altimeter

    @Test func altimeterFormatsStandardPressureBothWays() {
        #expect(UnitPreferences.icao.formatAltimeter(hPa: 1013.25) == "1013 hPa")
        #expect(UnitPreferences.faa.formatAltimeter(hPa: 1013.25) == "29.92 inHg")
    }

    @Test func altimeterMatchesTheDerivedModelProperty() {
        // Metar.altimeterInHg is the model's own conversion; the formatter must
        // not drift from it.
        let metar = Metar(station: ICAOIdentifier("EGLL"), raw: "", altimeterHpa: 1013.25)
        let fromModel = String(format: "%.2f inHg", metar.altimeterInHg!)
        #expect(UnitPreferences.faa.formatAltimeter(hPa: 1013.25) == fromModel)
    }

    @Test func spokenNameFollowsTheUnit() {
        #expect(UnitPreferences.Altimeter.inchesOfMercury.spokenName == "Altimeter")
        #expect(UnitPreferences.Altimeter.hectopascals.spokenName == "QNH")
    }

    // MARK: Visibility

    @Test func visibilityInStatuteMilesUsesFractions() {
        let faa = UnitPreferences.faa
        #expect(faa.formatVisibility(statuteMiles: 0.5) == "1/2 SM")
        #expect(faa.formatVisibility(statuteMiles: 1.5) == "1 1/2 SM")
        #expect(faa.formatVisibility(statuteMiles: 0.25) == "1/4 SM")
        #expect(faa.formatVisibility(statuteMiles: 10) == "10 SM")
    }

    @Test func visibilityInMetresRoundsToFiftyAndSwitchesToKmAboveFive() {
        let icao = UnitPreferences.icao
        // 1/2 SM ≈ 805 m → nearest 50.
        #expect(icao.formatVisibility(statuteMiles: 0.5) == "800 m")
        // 10 SM ≈ 16 km, above the 5 km switchover.
        #expect(icao.formatVisibility(statuteMiles: 10) == "16 km")
    }

    @Test func visibilityAtLeastSenseSurvivesConversion() {
        // "10+" must not silently become an exact 10 in any unit — that would
        // overstate what was actually observed.
        #expect(UnitPreferences.faa.formatVisibility(statuteMiles: 10, isAtLeast: true) == "≥10 SM")
        #expect(UnitPreferences.icao.formatVisibility(statuteMiles: 10, isAtLeast: true) == "≥16 km")
    }

    // MARK: Altitude, distance, speed

    @Test func altitudeConvertsFeetToMetres() {
        #expect(UnitPreferences.faa.formatAltitude(feet: 1000) == "1,000 ft")
        #expect(UnitPreferences.metric.formatAltitude(feet: 1000) == "305 m")
    }

    @Test func altitudeGroupsThousandsIndependentlyOfLocale() {
        #expect(UnitPreferences.grouped(999) == "999")
        #expect(UnitPreferences.grouped(1000) == "1,000")
        #expect(UnitPreferences.grouped(13500) == "13,500")
        #expect(UnitPreferences.grouped(1234567) == "1,234,567")
        #expect(UnitPreferences.grouped(0) == "0")
        #expect(UnitPreferences.grouped(-500) == "-500")
    }

    @Test func distanceConvertsFromNauticalMiles() {
        #expect(UnitPreferences.faa.formatDistance(nauticalMiles: 100) == "100.0 NM")
        #expect(UnitPreferences.metric.formatDistance(nauticalMiles: 100) == "185.2 km")

        var statute = UnitPreferences.faa
        statute.distance = .statuteMiles
        #expect(statute.formatDistance(nauticalMiles: 100) == "115.1 SM")
    }

    @Test func speedConvertsFromKnots() {
        #expect(UnitPreferences.faa.formatSpeed(knots: 120) == "120 kt")
        #expect(UnitPreferences.metric.formatSpeed(knots: 120) == "222 km/h")
    }

    // MARK: Round-trips

    @Test func conversionsRoundTripWithinTolerance() {
        let hPa = 1013.25
        let inHg = hPa / UnitPreferences.hPaPerInHg
        #expect(abs(inHg * UnitPreferences.hPaPerInHg - hPa) < 0.0001)

        let feet = 3500.0
        let metres = feet * UnitPreferences.metresPerFoot
        #expect(abs(metres / UnitPreferences.metresPerFoot - feet) < 0.0001)
    }

    @Test func distanceAndSpeedConstantsAreNotInterchanged() {
        // They are numerically equal; this pins the intent so a future edit to
        // one doesn't quietly change the other.
        #expect(UnitPreferences.kmPerNauticalMile == 1.852)
        #expect(UnitPreferences.kmPerKnot == 1.852)
    }

    @Test func codableRoundTrip() throws {
        let prefs = UnitPreferences.metric
        let decoded = try JSONDecoder().decode(UnitPreferences.self, from: JSONEncoder().encode(prefs))
        #expect(decoded == prefs)
    }
}
