import Foundation

public struct Airport: Codable, Sendable, Hashable, Identifiable {
    /// Primary identifier as published by the authority (FAA: the NASR ident, e.g. "AUS").
    public var id: String
    /// ICAO identifier where one exists (e.g. "KAUS").
    public var icaoId: ICAOIdentifier?
    public var name: String
    public var city: String?
    public var state: String?
    public var country: String
    public var coordinate: Coordinate
    public var elevationFeet: Double?
    /// Magnetic variation in degrees, east positive.
    public var magneticVariation: Double?
    public var authority: DataAuthority
    public var runways: [Runway]
    public var frequencies: [Frequency]

    public init(
        id: String,
        icaoId: ICAOIdentifier? = nil,
        name: String,
        city: String? = nil,
        state: String? = nil,
        country: String = "US",
        coordinate: Coordinate,
        elevationFeet: Double? = nil,
        magneticVariation: Double? = nil,
        authority: DataAuthority = .faa,
        runways: [Runway] = [],
        frequencies: [Frequency] = []
    ) {
        self.id = id
        self.icaoId = icaoId
        self.name = name
        self.city = city
        self.state = state
        self.country = country
        self.coordinate = coordinate
        self.elevationFeet = elevationFeet
        self.magneticVariation = magneticVariation
        self.authority = authority
        self.runways = runways
        self.frequencies = frequencies
    }

    /// The identifier pilots type and expect to see: ICAO if available, else the local ident.
    public var displayIdentifier: String { icaoId?.rawValue ?? id }
}

public struct Runway: Codable, Sendable, Hashable {
    /// Designator pair, e.g. "18L/36R".
    public var designator: String
    public var lengthFeet: Int?
    public var widthFeet: Int?
    public var surface: String?
    public var ends: [RunwayEnd]

    public init(designator: String, lengthFeet: Int? = nil, widthFeet: Int? = nil, surface: String? = nil, ends: [RunwayEnd] = []) {
        self.designator = designator
        self.lengthFeet = lengthFeet
        self.widthFeet = widthFeet
        self.surface = surface
        self.ends = ends
    }
}

public struct RunwayEnd: Codable, Sendable, Hashable {
    /// e.g. "18L"
    public var designator: String
    public var trueHeading: Double?
    public var coordinate: Coordinate?
    public var elevationFeet: Double?
    public var displacedThresholdFeet: Int?

    public init(designator: String, trueHeading: Double? = nil, coordinate: Coordinate? = nil, elevationFeet: Double? = nil, displacedThresholdFeet: Int? = nil) {
        self.designator = designator
        self.trueHeading = trueHeading
        self.coordinate = coordinate
        self.elevationFeet = elevationFeet
        self.displacedThresholdFeet = displacedThresholdFeet
    }
}

public struct Frequency: Codable, Sendable, Hashable {
    /// Use type, e.g. "TWR", "GND", "ATIS", "CTAF", "APP".
    public var use: String
    /// Frequency in kHz (e.g. 118_000 for 118.0 MHz) so it round-trips without float drift.
    public var kHz: Int
    public var remarks: String?

    public init(use: String, kHz: Int, remarks: String? = nil) {
        self.use = use
        self.kHz = kHz
        self.remarks = remarks
    }

    public var megahertzDisplay: String {
        String(format: "%.3f", Double(kHz) / 1000.0)
    }
}

public struct Navaid: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var kind: Kind
    public var coordinate: Coordinate
    public var frequencyKHz: Int?
    public var authority: DataAuthority

    public enum Kind: String, Codable, Sendable {
        case vor, vortac, vorDme, dme, ndb, tacan
    }

    public init(id: String, name: String, kind: Kind, coordinate: Coordinate, frequencyKHz: Int? = nil, authority: DataAuthority = .faa) {
        self.id = id
        self.name = name
        self.kind = kind
        self.coordinate = coordinate
        self.frequencyKHz = frequencyKHz
        self.authority = authority
    }
}

public struct Fix: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var coordinate: Coordinate
    public var authority: DataAuthority

    public init(id: String, coordinate: Coordinate, authority: DataAuthority = .faa) {
        self.id = id
        self.coordinate = coordinate
        self.authority = authority
    }
}
