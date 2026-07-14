import Foundation

/// A vertical extent in feet MSL, used to filter advisories by the altitude
/// a pilot plans to fly. Missing bounds are inclusive: an advisory without a
/// published floor or ceiling must never be hidden by an altitude filter.
public struct AltitudeBand: Sendable, Hashable {
    public var lowFt: Int?
    public var highFt: Int?

    public init(lowFt: Int? = nil, highFt: Int? = nil) {
        self.lowFt = lowFt
        self.highFt = highFt
    }

    public func contains(altitudeFt: Int) -> Bool {
        if let lowFt, altitudeFt < lowFt { return false }
        if let highFt, altitudeFt > highFt { return false }
        return true
    }

    /// Parse a published altitude into feet.
    ///
    /// Handles the formats the FAA products use: "SFC" (0), "FL 180"/"180 FL"
    /// (flight level), "4999 FT" / "4,800 ft MSL" (feet), bare numbers, and
    /// G-AIRMET hundreds-of-feet values ("240" → 24 000 with
    /// `hundredsOfFeet`). "UNL"/"FZL"/unparsable → nil (unbounded).
    public static func feet(fromText text: String?, hundredsOfFeet: Bool = false) -> Int? {
        guard let text else { return nil }
        let upper = text.uppercased().trimmingCharacters(in: .whitespaces)
        if upper.isEmpty || upper == "—" { return nil }
        if upper.contains("SFC") || upper.contains("GND") { return 0 }
        if upper.contains("UNL") || upper.contains("FZL") { return nil }

        let digits = upper.replacingOccurrences(of: ",", with: "")
            .drop(while: { !$0.isNumber })
            .prefix(while: \.isNumber)
        guard let value = Int(digits) else { return nil }

        if upper.contains("FL") {
            return value * 100
        }
        return hundredsOfFeet ? value * 100 : value
    }
}

public extension WeatherAdvisory {
    var altitudeBand: AltitudeBand {
        AltitudeBand(lowFt: altitudeLowFt, highFt: altitudeHiFt)
    }
}

public extension GraphicalAirmet {
    /// base/top publish in hundreds of feet ("240"), or "SFC"/"FZL".
    var altitudeBand: AltitudeBand {
        AltitudeBand(
            lowFt: AltitudeBand.feet(fromText: base, hundredsOfFeet: true),
            highFt: AltitudeBand.feet(fromText: top, hundredsOfFeet: true)
        )
    }
}

public extension TemporaryFlightRestriction.Area {
    /// floor/ceiling publish as "0 FT" / "4999 FT" / "180 FL".
    var altitudeBand: AltitudeBand {
        AltitudeBand(
            lowFt: AltitudeBand.feet(fromText: floorText),
            highFt: AltitudeBand.feet(fromText: ceilingText)
        )
    }
}
