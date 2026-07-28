import Foundation
import FBModels

/// Plain-English rendering of METARs and TAFs for the airport weather
/// section's "Decoded" mode. METARs decode from the already-parsed `Metar`
/// fields; TAFs are tokenized from raw text (group by group), so decoding
/// works offline on FIS-B uplinked text too.
///
/// Both US and ICAO report conventions are handled. The two differ in the raw
/// text — statute-mile visibility ("P6SM", "1/2SM") versus 4-digit metres
/// ("9999", "3000"), `A2992` versus `Q1013`, plus ICAO-only tokens like CAVOK
/// and NSW — while `units` independently controls how the decoded values are
/// *displayed*. A pilot can read a European TAF in statute miles, or a US one
/// in metres; parsing and presentation are separate concerns.
enum WeatherDecoder {
    // MARK: METAR

    static func decode(_ metar: Metar, units: UnitPreferences = .faa) -> [String] {
        var lines: [String] = []

        // Wind stays in knots regardless of preference: knots is the ICAO
        // reporting unit for surface wind worldwide. The `speed` preference
        // governs aircraft speeds (navlog TAS/groundspeed), not what the
        // observation said. Reports in metres per second are normalised to
        // knots on the way in, which is a unit fix, not a preference.
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
            // Prose rather than "≥" here: this is the plain-English pane. The
            // compact badge in WeatherSection uses the symbol form instead.
            let text = units.formatVisibility(statuteMiles: visibility)
            lines.append("Visibility \(text)\(metar.visibilityIsAtLeast ? " or more" : "")")
        }

        if let weather = metar.presentWeather, !weather.isEmpty {
            lines.append(decodePhenomena(weather))
        }

        if metar.clouds.isEmpty {
            // Only claim clear sky when the raw text says so; some reports
            // just omit sky condition.
            if metar.raw.contains("CAVOK") {
                lines.append("Ceiling and visibility OK")
            } else if metar.raw.contains("CLR") || metar.raw.contains("SKC") || metar.raw.contains("NSC") {
                lines.append("Sky clear")
            }
        } else {
            lines.append(describeClouds(metar.clouds, ceilingFeet: metar.ceilingFeet, units: units))
        }

        if let temperature = metar.temperatureC {
            var line = "Temperature \(Int(temperature.rounded()))°C"
            if units.showsFahrenheit {
                line += " (\(Int((temperature * 9 / 5 + 32).rounded()))°F)"
            }
            if let dewpoint = metar.dewpointC {
                line += ", dew point \(Int(dewpoint.rounded()))°C"
            }
            lines.append(line)
        }

        if let altimeter = metar.altimeterHpa {
            lines.append("\(units.altimeter.spokenName) \(units.formatAltimeter(hPa: altimeter))")
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
    static func decodeTAF(_ raw: String, units: UnitPreferences = .faa) -> [TafGroup] {
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
            } else if let condition = decodeToken(token, units: units) {
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
    static func decodeToken(_ token: String, units: UnitPreferences = .faa) -> String? {
        // Wind shear first: WS020/18040KT also ends in "KT", so checking it
        // after the wind group would let the wind parser claim and reject it.
        if token.hasPrefix("WS"), token.contains("/") {
            return "Low-level wind shear reported"
        }
        // Wind: dddffKT, dddffGffKT, VRBffKT. ICAO reports may use MPS
        // (metres per second) instead of knots.
        for (suffix, toKnots) in [("KT", 1.0), ("MPS", 1.9438444924406)] where token.hasSuffix(suffix) {
            let body = token.dropLast(suffix.count)
            let parts = body.split(separator: "G")
            let head = parts[0]
            guard head.count >= 5 else { return nil }
            let direction = head.prefix(3)
            let speed = head.dropFirst(3)
            guard speed.allSatisfy(\.isNumber), let value = Int(speed) else { return nil }
            let knots = Int((Double(value) * toKnots).rounded())
            var wind: String
            if direction == "VRB" {
                wind = "Wind variable at \(knots) kt"
            } else if direction.allSatisfy(\.isNumber) {
                wind = "Wind \(direction)° at \(knots) kt"
            } else {
                return nil
            }
            if parts.count == 2, let gust = Int(parts[1].filter(\.isNumber)) {
                wind += ", gusting \(Int((Double(gust) * toKnots).rounded())) kt"
            }
            return wind
        }
        // US visibility: P6SM, 6SM, 1/2SM; "1 1/2SM" arrives as "11/2SM".
        if token.hasSuffix("SM") {
            var body = String(token.dropLast(2))
            let atLeast = body.hasPrefix("P")
            if atLeast { body.removeFirst() }
            let below = body.hasPrefix("M")
            if below { body.removeFirst() }
            guard body.allSatisfy({ $0.isNumber || $0 == "/" }), let miles = statuteMiles(body) else { return nil }
            let text = units.formatVisibility(statuteMiles: miles)
            return "Visibility \(below ? "less than " : "")\(text)\(atLeast ? " or more" : "")"
        }
        // ICAO visibility: a bare 4-digit metre group ("9999", "3000", "0800"),
        // optionally with an NDV suffix. US TAFs never contain a bare 4-digit
        // token, so this cannot shadow them. 9999 means 10 km or more.
        if let metres = icaoVisibilityMetres(token) {
            let text = units.formatVisibility(metres: metres.value)
            return "Visibility \(text)\(metres.isAtLeast ? " or more" : "")"
        }
        // Pressure, when a report carries it: Q1013 (hPa) or A2992 (inHg×100).
        if let hPa = pressureHpa(token) {
            return "\(units.altimeter.spokenName) \(units.formatAltimeter(hPa: hPa))"
        }
        // Sky condition. CAVOK is not merely "clear" — it asserts visibility
        // 10 km or more, no cloud below 5000 ft, and no significant weather.
        if token == "CAVOK" { return "Ceiling and visibility OK" }
        if token == "SKC" || token == "CLR" || token == "NSC" || token == "NCD" { return "Sky clear" }
        if token == "NSW" { return "No significant weather" }
        // Clouds: FEW/SCT/BKN/OVC + hundreds of feet (+CB/TCU), VV002.
        for (prefix, name) in [("FEW", "Few clouds"), ("SCT", "Scattered clouds"), ("BKN", "Broken clouds"), ("OVC", "Overcast"), ("VV", "Sky obscured, vertical visibility")] {
            if token.hasPrefix(prefix) {
                var body = token.dropFirst(prefix.count)
                var suffix = ""
                if body.hasSuffix("CB") { body = body.dropLast(2); suffix = " (cumulonimbus)" }
                if body.hasSuffix("TCU") { body = body.dropLast(3); suffix = " (towering cumulus)" }
                guard body.count == 3, body.allSatisfy(\.isNumber), let hundreds = Int(body) else { return nil }
                return "\(name) at \(units.formatAltitude(feet: Double(hundreds * 100)))\(suffix)"
            }
        }
        // Weather phenomena.
        let phenomena = decodePhenomena(token)
        return phenomena == token ? nil : phenomena
    }

    /// "6" → 6, "1/2" → 0.5, "11/2" → 1.5 (the TAF spelling of "1 1/2").
    private static func statuteMiles(_ body: String) -> Double? {
        guard !body.isEmpty else { return nil }
        guard body.contains("/") else { return Double(body) }
        let parts = body.split(separator: "/")
        guard parts.count == 2, let denominator = Double(parts[1]), denominator != 0 else { return nil }
        // A 4-character form like "11/2" is a whole number glued to a fraction.
        if body.count == 4, parts[0].count == 2,
           let whole = Double(parts[0].prefix(1)), let numerator = Double(parts[0].suffix(1)) {
            return whole + numerator / denominator
        }
        guard let numerator = Double(parts[0]) else { return nil }
        return numerator / denominator
    }

    /// A bare ICAO metre visibility group. Returns nil for anything else, so
    /// the caller can fall through to the remaining token types.
    private static func icaoVisibilityMetres(_ token: String) -> (value: Double, isAtLeast: Bool)? {
        var body = token
        if body.hasSuffix("NDV") { body = String(body.dropLast(3)) }
        guard body.count == 4, body.allSatisfy(\.isNumber), let value = Int(body) else { return nil }
        // 9999 is the coded form of "10 km or more", not a 9,999 m observation.
        if value == 9999 { return (10_000, true) }
        return (Double(value), false)
    }

    /// "Q1013" → 1013 hPa; "A2992" → 29.92 inHg converted to hPa.
    private static func pressureHpa(_ token: String) -> Double? {
        guard token.count == 5 else { return nil }
        let digits = token.dropFirst()
        guard digits.allSatisfy(\.isNumber), let value = Double(digits) else { return nil }
        switch token.first {
        case "Q": return value
        case "A": return value / 100 * 33.863886666667
        default: return nil
        }
    }

    // MARK: Shared pieces

    private static func describeClouds(_ clouds: [CloudLayer], ceilingFeet: Int?, units: UnitPreferences) -> String {
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
            return "\(name) at \(units.formatAltitude(feet: Double(base)))\(ceiling)"
        }
        return "Clouds: " + parts.joined(separator: ", ")
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
