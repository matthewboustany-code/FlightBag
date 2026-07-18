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
        let lines = WeatherDecoder.decode(metar)
        #expect(lines.contains("Wind from 190° true at 10 kt, gusting 20 kt"))
        #expect(lines.contains("Visibility 10 or more statute miles"))
        #expect(lines.contains("Light rain"))
        #expect(lines.contains("Clouds: scattered at 4,500 ft, broken at 6,000 ft (ceiling)"))
        #expect(lines.contains("Temperature 32°C (90°F), dew point 22°C"))
        #expect(lines.contains("Altimeter 30.12 inHg"))
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
        let groups = WeatherDecoder.decodeTAF(raw)
        #expect(groups.count == 3)
        #expect(groups[0].header == "Valid 17/18Z – 18/24Z")
        #expect(groups[0].conditions.contains("Wind 180° at 12 kt, gusting 22 kt"))
        #expect(groups[0].conditions.contains("Visibility 6 or more SM"))
        #expect(groups[1].header == "From the 18th at 00:00Z")
        #expect(groups[1].conditions.contains("Broken clouds at 3,500 ft"))
        #expect(groups[2].header == "Temporarily 18/06Z – 18/10Z")
        #expect(groups[2].conditions.contains("Light thunderstorm with rain"))
        #expect(groups[2].conditions.contains("Broken clouds at 2,000 ft (cumulonimbus)"))
    }

    @Test func fractionalVisibilityAndProb() {
        let groups = WeatherDecoder.decodeTAF("TAF KXYZ 171720Z 1718/1824 09005KT 11/2SM BR PROB30 1720/1722 1/2SM FG")
        #expect(groups[0].conditions.contains("Visibility 1 1/2 SM"))
        #expect(groups[1].header == "30% chance 17/20Z – 17/22Z")
        #expect(groups[1].conditions.contains("Visibility 1/2 SM"))
        #expect(groups[1].conditions.contains("Fog"))
    }
}
