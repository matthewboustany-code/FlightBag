import Foundation

// In-flight hazard advisories drawn as map overlays: SIGMETs/AIRMETs,
// graphical AIRMETs (icing, turbulence, IFR), and TFRs.

/// A SIGMET, AIRMET, or convective outlook from the AWC `airsigmet` product.
public struct WeatherAdvisory: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case sigmet = "SIGMET"
        case airmet = "AIRMET"
        case outlook = "OUTLOOK"
    }

    public var id: String
    public var kind: Kind
    /// e.g. "CONVECTIVE", "TURB", "ICE", "IFR", "MTN OBSCN".
    public var hazard: String
    public var validFrom: Date
    public var validTo: Date
    public var altitudeLowFt: Int?
    public var altitudeHiFt: Int?
    public var rawText: String
    public var polygon: [Coordinate]

    public init(
        id: String,
        kind: Kind,
        hazard: String,
        validFrom: Date,
        validTo: Date,
        altitudeLowFt: Int? = nil,
        altitudeHiFt: Int? = nil,
        rawText: String = "",
        polygon: [Coordinate] = []
    ) {
        self.id = id
        self.kind = kind
        self.hazard = hazard
        self.validFrom = validFrom
        self.validTo = validTo
        self.altitudeLowFt = altitudeLowFt
        self.altitudeHiFt = altitudeHiFt
        self.rawText = rawText
        self.polygon = polygon
    }
}

/// A graphical AIRMET area from the AWC `gairmet` product.
public struct GraphicalAirmet: Codable, Sendable, Hashable, Identifiable {
    /// The G-AIRMET product family pilots brief by name.
    public enum Product: String, Codable, Sendable, CaseIterable {
        /// IFR conditions and mountain obscuration.
        case sierra = "SIERRA"
        /// Turbulence, low-level wind shear, surface winds.
        case tango = "TANGO"
        /// Icing and freezing level.
        case zulu = "ZULU"
    }

    public var id: String
    public var product: Product
    /// e.g. "IFR", "MT_OBSC", "TURB-HI", "TURB-LO", "LLWS", "ICE", "FZLVL".
    public var hazard: String
    public var validTime: Date
    public var expireTime: Date
    public var forecastHour: Int
    public var severity: String?
    /// Altitudes as published: hundreds of feet ("240") or "SFC"/"FZL".
    public var top: String?
    public var base: String?
    public var dueTo: String?
    /// True for area polygons; false for contour lines (e.g. freezing level).
    public var isArea: Bool
    public var polygon: [Coordinate]

    public init(
        id: String,
        product: Product,
        hazard: String,
        validTime: Date,
        expireTime: Date,
        forecastHour: Int,
        severity: String? = nil,
        top: String? = nil,
        base: String? = nil,
        dueTo: String? = nil,
        isArea: Bool = true,
        polygon: [Coordinate] = []
    ) {
        self.id = id
        self.product = product
        self.hazard = hazard
        self.validTime = validTime
        self.expireTime = expireTime
        self.forecastHour = forecastHour
        self.severity = severity
        self.top = top
        self.base = base
        self.dueTo = dueTo
        self.isArea = isArea
        self.polygon = polygon
    }
}

/// A Temporary Flight Restriction from tfr.faa.gov.
public struct TemporaryFlightRestriction: Codable, Sendable, Hashable, Identifiable {
    /// One restricted area within the TFR (many TFRs have several rings).
    public struct Area: Codable, Sendable, Hashable {
        public var name: String?
        /// e.g. "0 FT" / "4999 FT" / "UNL", as published.
        public var floorText: String?
        public var ceilingText: String?
        public var polygon: [Coordinate]

        public init(name: String? = nil, floorText: String? = nil, ceilingText: String? = nil, polygon: [Coordinate]) {
            self.name = name
            self.floorText = floorText
            self.ceilingText = ceilingText
            self.polygon = polygon
        }
    }

    /// NOTAM id, e.g. "6/5504".
    public var id: String
    /// e.g. "VIP", "HAZARDS", "SECURITY", "SPACE OPERATIONS".
    public var type: String?
    public var description: String
    public var effective: Date?
    public var expire: Date?
    public var areas: [Area]

    public init(id: String, type: String? = nil, description: String, effective: Date? = nil, expire: Date? = nil, areas: [Area]) {
        self.id = id
        self.type = type
        self.description = description
        self.effective = effective
        self.expire = expire
        self.areas = areas
    }
}
