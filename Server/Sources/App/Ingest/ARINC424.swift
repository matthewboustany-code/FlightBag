import Foundation

/// Fixed-width ARINC 424 line parsing for the FAA CIFP file — only the
/// record types the SID/STAR overlay needs. Pure functions, no I/O; column
/// offsets are guarded by fixture tests built from real CIFP lines.
enum ARINC424 {
    // MARK: Parsed records

    enum TransitionKind: String {
        case enroute, common, runway
    }

    struct ProcedureLeg {
        let airportId: String
        /// true = SID (subsection D), false = STAR (subsection E).
        let isSID: Bool
        let procedureIdent: String
        let transitionKind: TransitionKind
        /// nil for the common route ("ALL " transitions also normalize to nil).
        let transitionIdent: String?
        let sequence: Int
        let fixIdent: String
        /// Combined fix section+subsection, e.g. "EA", "PC", "PG", "D", "DB".
        let fixSection: String
        let pathTerminator: String
        let altitudeDescription: String?
        let altitude1Feet: Int?
        let speedLimitKt: Int?
    }

    struct Fix {
        let key: FixKey
        let latitude: Double
        let longitude: Double
    }

    /// Terminal fixes (PC waypoints, PG runways) are scoped to their
    /// airport; enroute waypoints and navaids are global.
    struct FixKey: Hashable {
        let section: String
        let airportId: String?
        let ident: String
    }

    enum Line {
        case leg(ProcedureLeg)
        case fix(Fix)
    }

    // MARK: Line parsing

    static func parse(_ line: String) -> Line? {
        let bytes = Array(line.utf8)
        guard bytes.count >= 51, bytes[0] == UInt8(ascii: "S") else { return nil }

        func field(_ range: ClosedRange<Int>) -> String {
            // 1-based spec columns.
            guard bytes.count >= range.upperBound else { return "" }
            return String(decoding: bytes[(range.lowerBound - 1)...(range.upperBound - 1)], as: UTF8.self)
        }
        func trimmed(_ range: ClosedRange<Int>) -> String {
            field(range).trimmingCharacters(in: .whitespaces)
        }

        let section = field(5...5)
        let subsection = field(6...6)

        switch (section, subsection) {
        case ("E", "A"):
            // Enroute waypoint: ident 14-18.
            guard field(22...22) <= "1" else { return nil }  // continuation records
            return coordinateFix(section: "EA", airportId: nil, ident: trimmed(14...18), bytes: bytes)
        case ("D", " "):
            // VHF navaid: ident 14-17.
            guard field(22...22) <= "1" else { return nil }
            return coordinateFix(section: "D", airportId: nil, ident: trimmed(14...17), bytes: bytes)
        case ("D", "B"):
            // NDB: ident 14-17.
            guard field(22...22) <= "1" else { return nil }
            return coordinateFix(section: "DB", airportId: nil, ident: trimmed(14...17), bytes: bytes)
        case ("P", " "):
            let airportId = trimmed(7...10)
            switch field(13...13) {
            case "C":
                // Terminal waypoint: ident 14-18.
                guard field(22...22) <= "1" else { return nil }
                return coordinateFix(section: "PC", airportId: airportId, ident: trimmed(14...18), bytes: bytes)
            case "G":
                // Runway record: ident 14-18 ("RW18L"); threshold coordinates.
                return coordinateFix(section: "PG", airportId: airportId, ident: trimmed(14...18), bytes: bytes)
            case "D", "E":
                return procedureLeg(airportId: airportId, isSID: field(13...13) == "D", field: field, trimmed: trimmed)
            default:
                return nil
            }
        default:
            return nil
        }
    }

    private static func procedureLeg(
        airportId: String,
        isSID: Bool,
        field: (ClosedRange<Int>) -> String,
        trimmed: (ClosedRange<Int>) -> String
    ) -> Line? {
        // Continuation records (col 39 > 1) repeat the primary's key fields.
        guard field(39...39) <= "1" else { return nil }
        let routeType = Character(field(20...20))
        guard let kind = transitionKind(routeType: routeType, isSID: isSID) else { return nil }
        guard let sequence = Int(trimmed(27...29)) else { return nil }
        let fixIdent = trimmed(30...34)
        guard !fixIdent.isEmpty else { return nil }  // fixless legs (CA/VM…): skipped
        var transition: String? = trimmed(21...25)
        if transition == "" || transition == "ALL" { transition = nil }

        let fixSection = (field(37...37) + field(38...38)).trimmingCharacters(in: .whitespaces)
        return .leg(ProcedureLeg(
            airportId: airportId,
            isSID: isSID,
            procedureIdent: trimmed(14...19),
            transitionKind: kind,
            transitionIdent: transition,
            sequence: sequence,
            fixIdent: fixIdent,
            fixSection: fixSection,
            pathTerminator: trimmed(48...49),
            altitudeDescription: trimmed(83...83).isEmpty ? nil : trimmed(83...83),
            altitude1Feet: Int(trimmed(85...89)),
            speedLimitKt: Int(trimmed(100...102))
        ))
    }

    /// Route type → transition kind. SID: 1/4/F/T runway, 2/5/M common,
    /// 3/6/S/V enroute. STAR (reversed flow): 1/4/7 enroute, 2/5/8 common,
    /// 3/6/9 runway.
    static func transitionKind(routeType: Character, isSID: Bool) -> TransitionKind? {
        if isSID {
            switch routeType {
            case "1", "4", "F", "T": return .runway
            case "2", "5", "M": return .common
            case "3", "6", "S", "V": return .enroute
            default: return nil
            }
        } else {
            switch routeType {
            case "1", "4", "7": return .enroute
            case "2", "5", "8": return .common
            case "3", "6", "9": return .runway
            default: return nil
            }
        }
    }

    private static func coordinateFix(section: String, airportId: String?, ident: String, bytes: [UInt8]) -> Line? {
        guard !ident.isEmpty,
              let coordinate = coordinate(
                latitude: String(decoding: bytes[32...40], as: UTF8.self),
                longitude: String(decoding: bytes[41...50], as: UTF8.self)
              ) else { return nil }
        return .fix(Fix(
            key: FixKey(section: section, airportId: airportId, ident: ident),
            latitude: coordinate.0,
            longitude: coordinate.1
        ))
    }

    /// "N30272321" / "W098173908" — DMS in hundredths of a second.
    static func coordinate(latitude: String, longitude: String) -> (Double, Double)? {
        func parse(_ text: String, degreeDigits: Int, positive: Character, negative: Character) -> Double? {
            guard let first = text.first, first == positive || first == negative else { return nil }
            let digits = Array(text.dropFirst())
            guard digits.count == degreeDigits + 6, digits.allSatisfy(\.isNumber) else { return nil }
            let degrees = Double(String(digits[0..<degreeDigits]))!
            let minutes = Double(String(digits[degreeDigits..<(degreeDigits + 2)]))!
            let secondsHundredths = Double(String(digits[(degreeDigits + 2)...]))!
            let value = degrees + minutes / 60 + secondsHundredths / 100 / 3600
            return first == negative ? -value : value
        }
        guard let lat = parse(latitude, degreeDigits: 2, positive: "N", negative: "S"),
              let lon = parse(longitude, degreeDigits: 3, positive: "E", negative: "W") else { return nil }
        return (lat, lon)
    }
}
