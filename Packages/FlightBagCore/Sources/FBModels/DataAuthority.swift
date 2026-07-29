import Foundation

/// The aeronautical data authority a piece of data originated from — that is,
/// who *published* it. Whose rules apply at a location is a separate question,
/// answered by `Jurisdiction`.
///
/// Every provider, database row, and download artifact is tagged with an
/// authority so new sources can be registered without reworking consumers.
public enum DataAuthority: String, Codable, Sendable, CaseIterable, Hashable {
    case faa
    case eurocontrol
    case navCanada
    /// Public-domain worldwide airport, runway and navaid data.
    case ourAirports
    /// Worldwide airspace, CC BY-NC.
    case openAIP
    /// VFR charts and AIP-derived data under the OFMA General Users' Licence.
    case openFlightMaps
    /// An authority this build does not know about — always the result of
    /// decoding, never something we publish.
    case unknown

    /// Decoding tolerates authorities this build has never heard of.
    ///
    /// Without this, an older app hitting a newer manifest that names a single
    /// unfamiliar authority fails to decode the *entire* `DownloadManifest`,
    /// taking every region with it — including the ones it does understand.
    /// Since the server gains authorities over time and app updates lag, that
    /// is a live failure mode, not a theoretical one.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DataAuthority(rawValue: raw) ?? .unknown
    }

    /// Authorities the app can actually present. Excludes `.unknown`, which is
    /// a decoding outcome rather than a real source.
    public static var known: [DataAuthority] {
        allCases.filter { $0 != .unknown }
    }

    public var displayName: String {
        switch self {
        case .faa: "FAA"
        case .eurocontrol: "Eurocontrol"
        case .navCanada: "Nav Canada"
        case .ourAirports: "OurAirports"
        case .openAIP: "openAIP"
        case .openFlightMaps: "open flightmaps"
        case .unknown: "Unknown source"
        }
    }

    /// Attribution required by the source's licence, where one applies.
    public var attribution: String? {
        switch self {
        case .ourAirports: "Data from OurAirports (public domain)."
        case .openAIP: "Airspace © openAIP contributors, CC BY-NC 4.0."
        case .openFlightMaps: "Charts © open flightmaps association, OFMA General Users' Licence."
        case .faa, .eurocontrol, .navCanada, .unknown: nil
        }
    }
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
