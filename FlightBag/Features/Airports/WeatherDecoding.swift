import Foundation
import FBModels

/// Plain-English rendering of METARs and TAFs for the airport weather
/// section's "Decoded" mode. METARs decode from the already-parsed `Metar`
/// fields; TAFs are tokenized from raw text (group by group), so decoding
/// works offline on FIS-B uplinked text too.
enum WeatherDecoder {
    // MARK: METAR

    static func decode(_ metar: Metar) -> [String] {
        var lines: [String] = []

        if let direction = metar.windDirectionDegrees, let speed = metar.windSpeedKt {
            var wind = "Wind from \(String(format: "%03d", direction))° true at \(speed) kt"
            if let gust = metar.windGustKt { wind += ", gusting \(gust) kt" }
            lines.append(wind)
        } else if metar.windIsVariable, let speed = metar.windSpeedKt {
            lines.append("Wind variable at \(speed) kt")
        } else if metar.windSpeedKt == 0 {
            lines.append("Wind calm")
        }

        if let visibility = metar.visibilitySM {
            lines.append("Visibility \(formatVisibility(visibility))\(metar.visibilityIsAtLeast ? " or more" : "") statute miles")
        }

        if let weather = metar.presentWeather, !weather.isEmpty {
            lines.append(decodePhenomena(weather))
        }

        if metar.clouds.isEmpty {
            // Only claim clear sky when the raw text says so; some reports
            // just omit sky condition.
            if metar.raw.contains("CLR") || metar.raw.contains("SKC") || metar.raw.contains("CAVOK") {
                lines.append("Sky clear")
            }
        } else {
            lines.append(describeClouds(metar.clouds, ceilingFeet: metar.ceilingFeet))
        }

        if let temperature = metar.temperatureC {
            var line = "Temperature \(Int(temperature.rounded()))°C (\(Int((temperature * 9 / 5 + 32).rounded()))°F)"
            if let dewpoint = metar.dewpointC {
                line += ", dew point \(Int(dewpoint.rounded()))°C"
            }
            lines.append(line)
        }

        if let altimeter = metar.altimeterInHg {
            lines.append(String(format: "Altimeter %.2f inHg", altimeter))
        }
        return lines
    }

    // MARK: TAF

    struct TafGroup: Equatable {
        /// "From the 17th at 18:00Z", "Temporarily 17/20Z – 17/24Z", …
        let header: String
        let conditions: [String]
    }

    /// Splits a raw TAF into its forecast groups and decodes each group's
    /// tokens. Unknown tokens are skipped, never guessed at.
    static func decodeTAF(_ raw: String) -> [TafGroup] {
        // One report, arbitrary whitespace/newlines → token stream.
        var tokens = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }
        if tokens.first == "TAF" { tokens.removeFirst() }
        if tokens.first == "AMD" || tokens.first == "COR" { tokens.removeFirst() }

        var groups: [(header: String, tokens: [String])] = []
        var current: (header: String, tokens: [String]) = ("Forecast", [])
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token.hasPrefix("FM"), token.count == 8, token.dropFirst(2).allSatisfy(\.isNumber) {
                groups.append(current)
                let day = token.dropFirst(2).prefix(2)
                let time = token.dropFirst(4)
                current = ("From the \(dayOrdinal(day)) at \(time.prefix(2)):\(time.suffix(2))Z", [])
            } else if token == "TEMPO" || token == "BECMG" || token.hasPrefix("PROB") {
                groups.append(current)
                var header = switch true {
                case token == "TEMPO": "Temporarily"
                case token == "BECMG": "Becoming"
                default: "\(token.dropFirst(4))% chance"
                }
                // PROB may be followed by TEMPO.
                if token.hasPrefix("PROB"), index + 1 < tokens.count, tokens[index + 1] == "TEMPO" {
                    index += 1
                }
                if index + 1 < tokens.count, let period = decodeValidity(tokens[index + 1]) {
                    header += " \(period)"
                    index += 1
                }
                current = (header, [])
            } else if let condition = decodeToken(token) {
                current.tokens.append(condition)
            } else if current.header == "Forecast", let period = decodeValidity(token) {
                current.header = "Valid \(period)"
            }
            index += 1
        }
        groups.append(current)
        return groups
            .filter { !$0.tokens.isEmpty }
            .map { TafGroup(header: $0.header, conditions: $0.tokens) }
    }

    /// "1718/1824" → "17/18Z – 18/24Z".
    private static func decodeValidity(_ token: String) -> String? {
        let parts = token.split(separator: "/")
        guard parts.count == 2, parts.allSatisfy({ $0.count == 4 && $0.allSatisfy(\.isNumber) }) else { return nil }
        return "\(parts[0].prefix(2))/\(parts[0].suffix(2))Z – \(parts[1].prefix(2))/\(parts[1].suffix(2))Z"
    }

    /// One TAF condition token → plain English, nil when unrecognized.
    static func decodeToken(_ token: String) -> String? {
        // Wind: dddffKT, dddffGffKT, VRBffKT.
        if token.hasSuffix("KT") {
            let body = token.dropLast(2)
            let parts = body.split(separator: "G")
            let head = parts[0]
            if head.count >= 5 {
                let direction = head.prefix(3)
                let speed = head.dropFirst(3)
                guard speed.allSatisfy(\.isNumber) else { return nil }
                var wind: String
                if direction == "VRB" {
                    wind = "Wind variable at \(Int(speed) ?? 0) kt"
                } else if direction.allSatisfy(\.isNumber) {
                    wind = "Wind \(direction)° at \(Int(speed) ?? 0) kt"
                } else {
                    return nil
                }
                if parts.count == 2, let gust = Int(parts[1]) { wind += ", gusting \(gust) kt" }
                return wind
            }
            return nil
        }
        // Visibility: P6SM, 6SM, 1/2SM, 1 1/2SM arrives as "11/2SM".
        if token.hasSuffix("SM") {
            var body = String(token.dropLast(2))
            let atLeast = body.hasPrefix("P")
            if atLeast { body.removeFirst() }
            guard body.allSatisfy({ $0.isNumber || $0 == "/" }) else { return nil }
            let display = body.count == 4 && body.contains("/")
                ? "\(body.prefix(1)) \(body.dropFirst())"  // "11/2" → "1 1/2"
                : body
            return "Visibility \(display)\(atLeast ? " or more" : "") SM"
        }
        // Clouds: FEW/SCT/BKN/OVC + hundreds of feet (+CB/TCU), VV002, SKC/CLR.
        if token == "SKC" || token == "CLR" || token == "CAVOK" { return "Sky clear" }
        for (prefix, name) in [("FEW", "Few clouds"), ("SCT", "Scattered clouds"), ("BKN", "Broken clouds"), ("OVC", "Overcast"), ("VV", "Sky obscured, vertical visibility")] {
            if token.hasPrefix(prefix) {
                var body = token.dropFirst(prefix.count)
                var suffix = ""
                if body.hasSuffix("CB") { body = body.dropLast(2); suffix = " (cumulonimbus)" }
                if body.hasSuffix("TCU") { body = body.dropLast(3); suffix = " (towering cumulus)" }
                guard body.count == 3, body.allSatisfy(\.isNumber), let hundreds = Int(body) else { return nil }
                return "\(name) at \((hundreds * 100).formatted()) ft\(suffix)"
            }
        }
        // Wind shear: WS020/18040KT.
        if token.hasPrefix("WS"), token.contains("/") {
            return "Low-level wind shear reported"
        }
        // Weather phenomena.
        let phenomena = decodePhenomena(token)
        return phenomena == token ? nil : phenomena
    }

    // MARK: Shared pieces

    private static func describeClouds(_ clouds: [CloudLayer], ceilingFeet: Int?) -> String {
        let parts = clouds.map { layer -> String in
            let name = switch layer.cover {
            case .skc, .clr, .cavok: "clear"
            case .few: "few"
            case .sct: "scattered"
            case .bkn: "broken"
            case .ovc: "overcast"
            case .ovx: "obscured"
            }
            guard let base = layer.baseFeetAGL else { return name }
            let ceiling = layer.cover.isCeiling && base == ceilingFeet ? " (ceiling)" : ""
            return "\(name) at \(base.formatted()) ft\(ceiling)"
        }
        return "Clouds: " + parts.joined(separator: ", ")
    }

    private static func formatVisibility(_ sm: Double) -> String {
        sm == sm.rounded() ? String(Int(sm)) : sm.formatted()
    }

    private static func dayOrdinal(_ day: Substring) -> String {
        guard let value = Int(day) else { return String(day) }
        let suffix = switch value % 10 {
        case 1 where value != 11: "st"
        case 2 where value != 12: "nd"
        case 3 where value != 13: "rd"
        default: "th"
        }
        return "\(value)\(suffix)"
    }

    /// "-TSRA BR" → "Light thunderstorm with rain, mist".
    static func decodePhenomena(_ raw: String) -> String {
        let codeNames: [(String, String)] = [
            ("MI", "shallow"), ("PR", "partial"), ("BC", "patches of"), ("DR", "drifting"),
            ("BL", "blowing"), ("SH", "showers of"), ("TS", "thunderstorm with"), ("FZ", "freezing"),
            ("DZ", "drizzle"), ("RA", "rain"), ("SN", "snow"), ("SG", "snow grains"),
            ("IC", "ice crystals"), ("PL", "ice pellets"), ("GR", "hail"), ("GS", "small hail"),
            ("UP", "precipitation"), ("BR", "mist"), ("FG", "fog"), ("FU", "smoke"),
            ("VA", "volcanic ash"), ("DU", "dust"), ("SA", "sand"), ("HZ", "haze"),
            ("PY", "spray"), ("PO", "dust whirls"), ("SQ", "squalls"), ("FC", "funnel cloud"),
            ("SS", "sandstorm"), ("DS", "duststorm"),
        ]
        let groups = raw.split(separator: " ").compactMap { group -> String? in
            var words: [String] = []
            var rest = Substring(group)
            if rest.hasPrefix("+") { words.append("heavy"); rest = rest.dropFirst() }
            else if rest.hasPrefix("-") { words.append("light"); rest = rest.dropFirst() }
            if rest.hasPrefix("VC") { words.append("nearby"); rest = rest.dropFirst(2) }
            while rest.count >= 2 {
                let code = String(rest.prefix(2))
                guard let name = codeNames.first(where: { $0.0 == code })?.1 else { return nil }
                words.append(name)
                rest = rest.dropFirst(2)
            }
            guard rest.isEmpty, !words.isEmpty else { return nil }
            // "thunderstorm with" at the end of a group loses its "with".
            if words.last == "thunderstorm with" { words[words.count - 1] = "thunderstorm" }
            if words.last == "showers of" { words[words.count - 1] = "showers" }
            return words.joined(separator: " ")
        }
        guard !groups.isEmpty else { return raw }
        return (groups.joined(separator: ", ")).prefix(1).uppercased() + groups.joined(separator: ", ").dropFirst()
    }
}
