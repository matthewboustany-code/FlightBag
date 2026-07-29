import Foundation

/// What kind of landing facility a row is, in one vocabulary that every
/// source is translated into.
///
/// The raw `site_type` column cannot answer this, because each authority
/// writes its own dialect there: NASR stores single letters (`A`, `H`, `C`)
/// while OurAirports stores words (`large_airport`, `heliport`,
/// `seaplane_base`). A query filtering `site_type = 'A'` therefore matches US
/// rows and silently excludes every other country — which is how the map and
/// the nearby list ended up US-only long after the worldwide data landed.
///
/// Sources keep their own value in `site_type` for provenance; `kind` is what
/// queries are allowed to key off.
public enum AirportKind: String, Codable, Sendable, CaseIterable, Hashable {
    case airport
    case heliport
    case seaplaneBase
    case balloonport
    case gliderport
    case ultralight
    /// Recognised as a facility, but not one of the categories above. Kept
    /// distinct from a decoding failure so an unfamiliar future value cannot
    /// masquerade as an airport.
    case other

    /// NASR `SITE_TYPE_CODE`.
    public static func fromNASR(siteTypeCode: String?) -> AirportKind {
        switch siteTypeCode?.uppercased() {
        case "A": .airport
        case "H": .heliport
        case "C": .seaplaneBase
        case "B": .balloonport
        case "G": .gliderport
        case "U": .ultralight
        default: .other
        }
    }

    /// OurAirports `type`.
    ///
    /// small/medium/large are a size split, not a category one — all three are
    /// airports, and collapsing them here is the point: size belongs to
    /// runway length and tower presence, which the map already computes for
    /// itself.
    public static func fromOurAirports(type: String?) -> AirportKind {
        switch type?.lowercased() {
        case "small_airport", "medium_airport", "large_airport": .airport
        case "heliport": .heliport
        case "seaplane_base": .seaplaneBase
        case "balloonport": .balloonport
        default: .other
        }
    }
}
