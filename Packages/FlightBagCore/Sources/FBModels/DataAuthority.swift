import Foundation

/// The aeronautical data authority a piece of data originated from.
///
/// v1 ships FAA only, but every provider, database row, and download artifact
/// is tagged with an authority so international sources (Eurocontrol,
/// Nav Canada, …) can be registered later without reworking consumers.
public enum DataAuthority: String, Codable, Sendable, CaseIterable, Hashable {
    case faa
    case eurocontrol
    case navCanada
}

/// An ICAO (or FAA local) location identifier, e.g. "KAUS", "3R9".
public struct ICAOIdentifier: RawRepresentable, Codable, Sendable, Hashable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue.uppercased()
    }

    public init(_ value: String) {
        self.init(rawValue: value)
    }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
