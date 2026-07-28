import Foundation

/// How measurements are displayed. Storage stays canonical everywhere in
/// FlightBag — pressure in hPa, visibility in statute miles, altitude in feet,
/// distance in nautical miles, speed in knots, matching what the models and
/// upstream feeds already carry — and only presentation varies. Nothing here
/// converts stored data; the formatters convert on the way to the screen.
///
/// Temperature is deliberately absent: aviation reports Celsius worldwide.
public struct UnitPreferences: Codable, Sendable, Hashable {
    public enum Altimeter: String, Codable, Sendable, CaseIterable {
        case inchesOfMercury
        case hectopascals

        public var symbol: String {
            switch self {
            case .inchesOfMercury: "inHg"
            case .hectopascals: "hPa"
            }
        }

        /// What ATC calls the setting. "Altimeter" is FAA phraseology; the
        /// rest of the world says "QNH".
        public var spokenName: String {
            switch self {
            case .inchesOfMercury: "Altimeter"
            case .hectopascals: "QNH"
            }
        }
    }

    public enum Distance: String, Codable, Sendable, CaseIterable {
        case nauticalMiles
        case kilometres
        case statuteMiles

        public var symbol: String {
            switch self {
            case .nauticalMiles: "NM"
            case .kilometres: "km"
            case .statuteMiles: "SM"
            }
        }
    }

    public enum Visibility: String, Codable, Sendable, CaseIterable {
        case statuteMiles
        case metres
        case kilometres

        public var symbol: String {
            switch self {
            case .statuteMiles: "SM"
            case .metres: "m"
            case .kilometres: "km"
            }
        }
    }

    public enum Altitude: String, Codable, Sendable, CaseIterable {
        case feet
        case metres

        public var symbol: String {
            switch self {
            case .feet: "ft"
            case .metres: "m"
            }
        }
    }

    /// Runway length and width, which do **not** follow `Altitude`.
    ///
    /// The two look interchangeable and are not: outside North America a state
    /// flies altitudes in feet while publishing runway dimensions in metres —
    /// Heathrow's 09L/27R is 3902 m in the UK AIP, and rendering it as
    /// "12,799 ft" is a number no British chart, plate or ATIS will ever
    /// confirm. Canada is the reverse case that rules out keying off the
    /// altimeter setting: inHg, but runways in feet.
    public enum RunwayLength: String, Codable, Sendable, CaseIterable {
        case feet
        case metres

        public var symbol: String {
            switch self {
            case .feet: "ft"
            case .metres: "m"
            }
        }
    }

    /// Governs *aircraft* speeds — navlog TAS and groundspeed. Reported
    /// surface wind is always shown in knots, the ICAO reporting unit
    /// worldwide; a preference has no business rewriting an observation.
    public enum Speed: String, Codable, Sendable, CaseIterable {
        case knots
        case kilometresPerHour

        public var symbol: String {
            switch self {
            case .knots: "kt"
            case .kilometresPerHour: "km/h"
            }
        }
    }

    public var altimeter: Altimeter
    public var distance: Distance
    public var visibility: Visibility
    public var altitude: Altitude
    public var runwayLength: RunwayLength
    public var speed: Speed
    /// Aviation temperature is Celsius everywhere; US pilots conventionally
    /// see a Fahrenheit gloss alongside it. Explicit rather than inferred from
    /// another unit — Canada uses inHg without wanting Fahrenheit.
    public var showsFahrenheit: Bool

    public init(
        altimeter: Altimeter = .inchesOfMercury,
        distance: Distance = .nauticalMiles,
        visibility: Visibility = .statuteMiles,
        altitude: Altitude = .feet,
        runwayLength: RunwayLength = .feet,
        speed: Speed = .knots,
        showsFahrenheit: Bool = false
    ) {
        self.altimeter = altimeter
        self.distance = distance
        self.visibility = visibility
        self.altitude = altitude
        self.runwayLength = runwayLength
        self.speed = speed
        self.showsFahrenheit = showsFahrenheit
    }

    /// Decoding tolerates preferences written by an older build that had
    /// fewer fields.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        altimeter = try container.decodeIfPresent(Altimeter.self, forKey: .altimeter) ?? .inchesOfMercury
        distance = try container.decodeIfPresent(Distance.self, forKey: .distance) ?? .nauticalMiles
        visibility = try container.decodeIfPresent(Visibility.self, forKey: .visibility) ?? .statuteMiles
        altitude = try container.decodeIfPresent(Altitude.self, forKey: .altitude) ?? .feet
        runwayLength = try container.decodeIfPresent(RunwayLength.self, forKey: .runwayLength) ?? .feet
        speed = try container.decodeIfPresent(Speed.self, forKey: .speed) ?? .knots
        showsFahrenheit = try container.decodeIfPresent(Bool.self, forKey: .showsFahrenheit) ?? false
    }

    // MARK: Presets

    /// US convention: inches of mercury, statute-mile visibility.
    public static let faa = UnitPreferences(
        altimeter: .inchesOfMercury,
        distance: .nauticalMiles,
        visibility: .statuteMiles,
        altitude: .feet,
        runwayLength: .feet,
        speed: .knots,
        showsFahrenheit: true
    )

    /// The common ICAO convention outside North America: hectopascals and
    /// metre/kilometre visibility, feet and knots in the air — but runways on
    /// the ground in metres, which is how the AIPs publish them.
    public static let icao = UnitPreferences(
        altimeter: .hectopascals,
        distance: .nauticalMiles,
        visibility: .metres,
        altitude: .feet,
        runwayLength: .metres,
        speed: .knots
    )

    /// States that publish altitudes in metres (China, Russia, Mongolia, DPRK).
    public static let metric = UnitPreferences(
        altimeter: .hectopascals,
        distance: .kilometres,
        visibility: .metres,
        altitude: .metres,
        runwayLength: .metres,
        speed: .kilometresPerHour
    )

    // MARK: Conversion constants

    static let hPaPerInHg = 33.863886666667
    static let metresPerFoot = 0.3048
    static let metresPerNauticalMile = 1852.0
    static let metresPerStatuteMile = 1609.344
    /// Numerically equal to `kmPerKnot`, but kept separate so distance and
    /// speed conversions can't be silently swapped.
    static let kmPerNauticalMile = 1.852
    static let kmPerKnot = 1.852

    // MARK: Formatting

    /// Formats a pressure stored in hectopascals. hPa is shown as a whole
    /// number (1013), inHg to two decimals (29.92) — the conventions ATC uses.
    public func formatAltimeter(hPa: Double) -> String {
        switch altimeter {
        case .hectopascals:
            return "\(Int(hPa.rounded())) \(altimeter.symbol)"
        case .inchesOfMercury:
            return String(format: "%.2f %@", hPa / Self.hPaPerInHg, altimeter.symbol)
        }
    }

    /// Formats a visibility stored in statute miles — the unit
    /// aviationweather.gov normalises to, worldwide.
    ///
    /// `isAtLeast` carries the "10+"/P6SM/9999 sense — a reported floor rather
    /// than an exact value — and must survive the conversion, since hiding it
    /// would overstate what was actually observed.
    public func formatVisibility(statuteMiles: Double, isAtLeast: Bool = false) -> String {
        formatVisibility(metres: statuteMiles * Self.metresPerStatuteMile, isAtLeast: isAtLeast)
    }

    /// Formats a visibility given in metres — the unit ICAO reports use, so
    /// tokens read straight out of a non-US METAR/TAF need no lossy detour
    /// through statute miles first.
    public func formatVisibility(metres: Double, isAtLeast: Bool = false) -> String {
        let prefix = isAtLeast ? "≥" : ""
        switch visibility {
        case .statuteMiles:
            let miles = metres / Self.metresPerStatuteMile
            return "\(prefix)\(Self.fractionalMiles(miles)) \(visibility.symbol)"
        case .kilometres:
            return String(format: "%@%.1f %@", prefix, metres / 1000, visibility.symbol)
        case .metres:
            // ICAO reports metres up to 5 km and kilometres above it.
            if metres >= 5000 {
                return String(format: "%@%.0f km", prefix, (metres / 1000).rounded())
            }
            // Rounded to the nearest 50 m, as METAR reports it.
            let rounded = (metres / 50).rounded() * 50
            return "\(prefix)\(Int(rounded)) \(visibility.symbol)"
        }
    }

    /// Formats an altitude or elevation stored in feet.
    public func formatAltitude(feet: Double) -> String {
        switch altitude {
        case .feet:
            return "\(Self.grouped(Int(feet.rounded()))) \(altitude.symbol)"
        case .metres:
            return "\(Self.grouped(Int((feet * Self.metresPerFoot).rounded()))) \(altitude.symbol)"
        }
    }

    /// Thousands separator for altitudes and runway lengths ("4,500 ft").
    ///
    /// Deliberately not `Int.formatted()`: that follows the device locale, so
    /// the same altitude would render differently for different users and
    /// tests comparing exact strings would pass or fail by locale.
    static func grouped(_ value: Int) -> String {
        let digits = String(abs(value))
        var out = ""
        for (offset, character) in digits.enumerated() {
            if offset > 0, (digits.count - offset) % 3 == 0 { out.append(",") }
            out.append(character)
        }
        return value < 0 ? "-\(out)" : out
    }

    /// Formats a horizontal distance stored in nautical miles.
    public func formatDistance(nauticalMiles: Double) -> String {
        switch distance {
        case .nauticalMiles:
            return String(format: "%.1f %@", nauticalMiles, distance.symbol)
        case .kilometres:
            return String(format: "%.1f %@", nauticalMiles * Self.kmPerNauticalMile, distance.symbol)
        case .statuteMiles:
            let miles = nauticalMiles * Self.metresPerNauticalMile / Self.metresPerStatuteMile
            return String(format: "%.1f %@", miles, distance.symbol)
        }
    }

    /// Formats a speed stored in knots.
    public func formatSpeed(knots: Double) -> String {
        switch speed {
        case .knots:
            return "\(Int(knots.rounded())) \(speed.symbol)"
        case .kilometresPerHour:
            return "\(Int((knots * Self.kmPerKnot).rounded())) \(speed.symbol)"
        }
    }

    /// Runway and field dimensions, which are published in feet by the FAA and
    /// OurAirports alike but read in metres almost everywhere else.
    /// Runway length or width. Whole units either way — no aerodrome publishes
    /// a fractional runway.
    ///
    /// Storage is feet, so a metric render is a round trip through the
    /// conversion the source already made and can land a metre off the
    /// published figure (EGLL 09L/27R reads 3901 m against the AIP's 3902).
    /// Displaying metres is still the right call: a metre of rounding is
    /// invisible next to being handed a unit the local charts never use.
    public func formatRunwayLength(feet: Double) -> String {
        switch runwayLength {
        case .feet:
            return "\(Self.grouped(Int(feet.rounded()))) \(runwayLength.symbol)"
        case .metres:
            return "\(Self.grouped(Int((feet * Self.metresPerFoot).rounded()))) \(runwayLength.symbol)"
        }
    }

    /// US visibility is spoken in fractions ("1 1/2", "1/2"), not decimals.
    static func fractionalMiles(_ miles: Double) -> String {
        guard miles < 4 else { return "\(Int(miles.rounded()))" }
        let whole = Int(miles)
        let fraction = miles - Double(whole)
        let eighths = Int((fraction * 8).rounded())
        guard eighths > 0 else { return "\(whole)" }
        guard eighths < 8 else { return "\(whole + 1)" }

        var numerator = eighths
        var denominator = 8
        while numerator % 2 == 0 && denominator % 2 == 0 {
            numerator /= 2
            denominator /= 2
        }
        return whole > 0 ? "\(whole) \(numerator)/\(denominator)" : "\(numerator)/\(denominator)"
    }
}
