import Foundation

/// A downloadable coverage area the user picks in the Downloads tab.
///
/// v1 regions are US states, but the shape is authority-agnostic: ids follow
/// ISO 3166-2 where one exists ("US-TX"), and `kind` distinguishes future
/// region styles (whole countries, curated groupings like "Caribbean") so
/// worldwide coverage is a manifest change, not an app change. Regions are
/// published in the `DownloadManifest`; the app never hardcodes a list.
public struct Region: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// Display name, e.g. "Texas".
    public var name: String
    public var authority: DataAuthority
    public var kind: Kind

    public enum Kind: String, Codable, Sendable {
        case stateOrProvince
        case country
        case custom
    }

    public init(id: String, name: String, authority: DataAuthority, kind: Kind) {
        self.id = id
        self.name = name
        self.authority = authority
        self.kind = kind
    }
}
