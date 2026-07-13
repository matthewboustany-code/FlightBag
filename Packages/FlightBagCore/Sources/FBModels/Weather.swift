import Foundation

public enum FlightCategory: String, Codable, Sendable, CaseIterable {
    case vfr = "VFR"
    case mvfr = "MVFR"
    case ifr = "IFR"
    case lifr = "LIFR"

    /// Standard US flight-category rules from ceiling (ft AGL) and visibility (SM).
    public static func from(ceilingFeet: Int?, visibilitySM: Double?) -> FlightCategory? {
        guard ceilingFeet != nil || visibilitySM != nil else { return nil }
        let ceiling = ceilingFeet ?? .max
        let vis = visibilitySM ?? .greatestFiniteMagnitude
        if ceiling < 500 || vis < 1 { return .lifr }
        if ceiling < 1000 || vis < 3 { return .ifr }
        if ceiling <= 3000 || vis <= 5 { return .mvfr }
        return .vfr
    }
}

public enum CloudCover: String, Codable, Sendable {
    case skc = "SKC"
    case clr = "CLR"
    case cavok = "CAVOK"
    case few = "FEW"
    case sct = "SCT"
    case bkn = "BKN"
    case ovc = "OVC"
    case ovx = "OVX"

    public var isCeiling: Bool {
        self == .bkn || self == .ovc || self == .ovx
    }
}

public struct CloudLayer: Codable, Sendable, Hashable {
    public var cover: CloudCover
    public var baseFeetAGL: Int?

    public init(cover: CloudCover, baseFeetAGL: Int? = nil) {
        self.cover = cover
        self.baseFeetAGL = baseFeetAGL
    }
}

/// A decoded METAR. `raw` is always preserved — pilots read raw text.
public struct Metar: Codable, Sendable, Hashable {
    public var station: ICAOIdentifier
    public var raw: String
    public var observationTime: Date?
    public var temperatureC: Double?
    public var dewpointC: Double?
    /// Wind direction in degrees true; nil when calm or variable.
    public var windDirectionDegrees: Int?
    public var windIsVariable: Bool
    public var windSpeedKt: Int?
    public var windGustKt: Int?
    public var visibilitySM: Double?
    /// True when visibility was reported as "10+" style (at least that value).
    public var visibilityIsAtLeast: Bool
    public var altimeterHpa: Double?
    public var presentWeather: String?
    public var clouds: [CloudLayer]
    private var reportedCategory: FlightCategory?

    public init(
        station: ICAOIdentifier,
        raw: String,
        observationTime: Date? = nil,
        temperatureC: Double? = nil,
        dewpointC: Double? = nil,
        windDirectionDegrees: Int? = nil,
        windIsVariable: Bool = false,
        windSpeedKt: Int? = nil,
        windGustKt: Int? = nil,
        visibilitySM: Double? = nil,
        visibilityIsAtLeast: Bool = false,
        altimeterHpa: Double? = nil,
        presentWeather: String? = nil,
        clouds: [CloudLayer] = [],
        reportedCategory: FlightCategory? = nil
    ) {
        self.station = station
        self.raw = raw
        self.observationTime = observationTime
        self.temperatureC = temperatureC
        self.dewpointC = dewpointC
        self.windDirectionDegrees = windDirectionDegrees
        self.windIsVariable = windIsVariable
        self.windSpeedKt = windSpeedKt
        self.windGustKt = windGustKt
        self.visibilitySM = visibilitySM
        self.visibilityIsAtLeast = visibilityIsAtLeast
        self.altimeterHpa = altimeterHpa
        self.presentWeather = presentWeather
        self.clouds = clouds
        self.reportedCategory = reportedCategory
    }

    /// Lowest broken/overcast/obscured layer base, ft AGL.
    public var ceilingFeet: Int? {
        clouds.filter { $0.cover.isCeiling }.compactMap(\.baseFeetAGL).min()
    }

    /// Reported category when the source provided one, otherwise computed.
    public var flightCategory: FlightCategory? {
        reportedCategory ?? .from(ceilingFeet: ceilingFeet, visibilitySM: visibilitySM)
    }

    public var altimeterInHg: Double? {
        altimeterHpa.map { $0 * 0.029529983071445 }
    }
}

/// A TAF. Decoded forecast groups come later; raw text + validity is what
/// Phase 1 renders.
public struct Taf: Codable, Sendable, Hashable {
    public var station: ICAOIdentifier
    public var raw: String
    public var issueTime: Date?
    public var validFrom: Date?
    public var validTo: Date?

    public init(station: ICAOIdentifier, raw: String, issueTime: Date? = nil, validFrom: Date? = nil, validTo: Date? = nil) {
        self.station = station
        self.raw = raw
        self.issueTime = issueTime
        self.validFrom = validFrom
        self.validTo = validTo
    }
}

public struct Notam: Codable, Sendable, Hashable, Identifiable {
    /// NOTAM number, e.g. "01/005".
    public var id: String
    public var location: ICAOIdentifier
    public var text: String
    public var classification: String?
    public var effectiveStart: Date?
    public var effectiveEnd: Date?
    /// True when the end time is "PERM" or estimated.
    public var endIsEstimated: Bool

    public init(
        id: String,
        location: ICAOIdentifier,
        text: String,
        classification: String? = nil,
        effectiveStart: Date? = nil,
        effectiveEnd: Date? = nil,
        endIsEstimated: Bool = false
    ) {
        self.id = id
        self.location = location
        self.text = text
        self.classification = classification
        self.effectiveStart = effectiveStart
        self.effectiveEnd = effectiveEnd
        self.endIsEstimated = endIsEstimated
    }
}
