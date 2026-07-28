import Foundation
import Testing
import FBModels
@testable import FlightBag

@Suite struct WeatherDecoderTests {
    @Test func decodesMetarFields() {
        let metar = Metar(
            station: ICAOIdentifier("KAUS"),
            raw: "METAR KAUS 171853Z 19010G20KT 10SM -RA SCT045 BKN060 32/22 A3012",
            temperatureC: 32,
            dewpointC: 22,
            windDirectionDegrees: 190,
            windSpeedKt: 10,
            windGustKt: 20,
            visibilitySM: 10,
            visibilityIsAtLeast: true,
            altimeterHpa: 30.12 / 0.029529983071445,
            presentWeather: "-RA",
            clouds: [
                CloudLayer(cover: .sct, baseFeetAGL: 4500),
                CloudLayer(cover: .bkn, baseFeetAGL: 6000),
            ]
        )
        let lines = WeatherDecoder.decode(metar, units: .faa)
        #expect(lines.contains("Wind from 190° true at 10 kt, gusting 20 kt"))
        #expect(lines.contains("Visibility 10 SM or more"))
        #expect(lines.contains("Light rain"))
        #expect(lines.contains("Clouds: scattered at 4,500 ft, broken at 6,000 ft (ceiling)"))
        #expect(lines.contains("Temperature 32°C (90°F), dew point 22°C"))
        #expect(lines.contains("Altimeter 30.12 inHg"))
    }

    /// The same observation, read by a pilot on ICAO units.
    @Test func decodesSameMetarInICAOUnits() {
        let metar = Metar(
            station: ICAOIdentifier("EGLL"),
            raw: "METAR EGLL 171850Z 25012KT 9999 SCT035 12/08 Q1013",
            temperatureC: 12,
            dewpointC: 8,
            windDirectionDegrees: 250,
            windSpeedKt: 12,
            visibilitySM: 6.21,
            visibilityIsAtLeast: true,
            altimeterHpa: 1013,
            clouds: [CloudLayer(cover: .sct, baseFeetAGL: 3500)]
        )
        let lines = WeatherDecoder.decode(metar, units: .icao)
        #expect(lines.contains("QNH 1013 hPa"))
        #expect(lines.contains("Visibility 10 km or more"))
        #expect(lines.contains("Clouds: scattered at 3,500 ft"))
        // No Fahrenheit gloss outside the US preset.
        #expect(lines.contains("Temperature 12°C, dew point 8°C"))
        // Wind is knots everywhere — it is the ICAO reporting unit.
        #expect(lines.contains("Wind from 250° true at 12 kt"))
    }

    @Test func metricPresetConvertsCloudBasesToMetres() {
        let metar = Metar(
            station: ICAOIdentifier("ZBAA"),
            raw: "METAR ZBAA 171800Z 30004MPS 3000 BR SCT033 05/M02 Q1021",
            altimeterHpa: 1021,
            clouds: [CloudLayer(cover: .sct, baseFeetAGL: 3300)]
        )
        let lines = WeatherDecoder.decode(metar, units: .metric)
        #expect(lines.contains("Clouds: scattered at 1,006 m"))
        #expect(lines.contains("QNH 1021 hPa"))
    }

    @Test func decodesPhenomenaCombinations() {
        #expect(WeatherDecoder.decodePhenomena("+TSRA") == "Heavy thunderstorm with rain")
        #expect(WeatherDecoder.decodePhenomena("-RA BR") == "Light rain, mist")
        #expect(WeatherDecoder.decodePhenomena("VCSH") == "Nearby showers")
        #expect(WeatherDecoder.decodePhenomena("FZFG") == "Freezing fog")
    }

    @Test func decodesTafGroups() {
        let raw = """
        TAF KAUS 171720Z 1718/1824 18012G22KT P6SM SCT050
        FM180000 17008KT P6SM BKN035
        TEMPO 1806/1810 4SM -TSRA BKN020CB
        """
        let groups = WeatherDecoder.decodeTAF(raw, units: .faa)
        #expect(groups.count == 3)
        #expect(groups[0].header == "Valid 17/18Z – 18/24Z")
        #expect(groups[0].conditions.contains("Wind 180° at 12 kt, gusting 22 kt"))
        #expect(groups[0].conditions.contains("Visibility 6 SM or more"))
        #expect(groups[1].header == "From the 18th at 00:00Z")
        #expect(groups[1].conditions.contains("Broken clouds at 3,500 ft"))
        #expect(groups[2].header == "Temporarily 18/06Z – 18/10Z")
        #expect(groups[2].conditions.contains("Light thunderstorm with rain"))
        #expect(groups[2].conditions.contains("Broken clouds at 2,000 ft (cumulonimbus)"))
    }

    @Test func fractionalVisibilityAndProb() {
        let groups = WeatherDecoder.decodeTAF(
            "TAF KXYZ 171720Z 1718/1824 09005KT 11/2SM BR PROB30 1720/1722 1/2SM FG",
            units: .faa
        )
        #expect(groups[0].conditions.contains("Visibility 1 1/2 SM"))
        #expect(groups[1].header == "30% chance 17/20Z – 17/22Z")
        #expect(groups[1].conditions.contains("Visibility 1/2 SM"))
        #expect(groups[1].conditions.contains("Fog"))
    }

    // MARK: ICAO report forms

    @Test func decodesEuropeanTafWithMetreVisibility() {
        let raw = """
        TAF EGLL 171658Z 1718/1824 25012KT 9999 SCT035
        BECMG 1720/1722 3000 BR BKN008
        TEMPO 1802/1806 0800 FG VV002
        """
        let groups = WeatherDecoder.decodeTAF(raw, units: .icao)
        #expect(groups[0].conditions.contains("Visibility 10 km or more"))
        #expect(groups[1].conditions.contains("Visibility 3000 m"))
        #expect(groups[1].conditions.contains("Mist"))
        #expect(groups[2].conditions.contains("Visibility 800 m"))
        #expect(groups[2].conditions.contains("Fog"))
    }

    /// 9999 is the coded form of "10 km or more", not a 9,999 m observation.
    @Test func nineNinesMeansTenKilometresOrMore() {
        #expect(WeatherDecoder.decodeToken("9999", units: .icao) == "Visibility 10 km or more")
        #expect(WeatherDecoder.decodeToken("9999", units: .faa) == "Visibility 6 SM or more")
    }

    @Test func metreVisibilityRendersInWhicheverUnitIsPreferred() {
        #expect(WeatherDecoder.decodeToken("3000", units: .icao) == "Visibility 3000 m")
        #expect(WeatherDecoder.decodeToken("3000", units: .faa) == "Visibility 1 7/8 SM")
    }

    @Test func decodesPressureTokensBothWays() {
        #expect(WeatherDecoder.decodeToken("Q1013", units: .icao) == "QNH 1013 hPa")
        #expect(WeatherDecoder.decodeToken("A2992", units: .faa) == "Altimeter 29.92 inHg")
        // Cross-converted on request. 1013 hPa is 29.91 inHg — standard
        // pressure is 1013.25, which is what rounds to 29.92.
        #expect(WeatherDecoder.decodeToken("Q1013", units: .faa) == "Altimeter 29.91 inHg")
    }

    @Test func decodesICAOOnlySkyAndWeatherTokens() {
        #expect(WeatherDecoder.decodeToken("CAVOK", units: .icao) == "Ceiling and visibility OK")
        #expect(WeatherDecoder.decodeToken("NSC", units: .icao) == "Sky clear")
        #expect(WeatherDecoder.decodeToken("NCD", units: .icao) == "Sky clear")
        #expect(WeatherDecoder.decodeToken("NSW", units: .icao) == "No significant weather")
    }

    @Test func normalisesMetresPerSecondWindToKnots() {
        // 10 MPS ≈ 19 kt. Russia and China report wind this way.
        #expect(WeatherDecoder.decodeToken("30010MPS", units: .icao) == "Wind 300° at 19 kt")
        #expect(WeatherDecoder.decodeToken("VRB03MPS", units: .icao) == "Wind variable at 6 kt")
        #expect(WeatherDecoder.decodeToken("25012KT", units: .icao) == "Wind 250° at 12 kt")
    }

    /// WS020/18040KT ends in "KT", so the wind parser must not claim it first.
    @Test func windShearIsNotSwallowedByTheWindParser() {
        #expect(WeatherDecoder.decodeToken("WS020/18040KT", units: .faa) == "Low-level wind shear reported")
    }

    @Test func usTafDecodingIsUnaffectedByMetreSupport() {
        // A US TAF contains no bare 4-digit token, so the ICAO visibility
        // branch cannot shadow anything here.
        let groups = WeatherDecoder.decodeTAF(
            "TAF KAUS 171720Z 1718/1824 18012KT P6SM SCT050",
            units: .faa
        )
        #expect(groups[0].conditions.contains("Visibility 6 SM or more"))
        #expect(groups[0].conditions.contains("Scattered clouds at 5,000 ft"))
    }
}
