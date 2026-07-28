import Foundation
import FBModels

/// How the user wants measurements shown.
///
/// `.automatic` is the default and the interesting one: it follows the
/// jurisdiction of whatever the screen is showing, so a US pilot planning
/// KAUS→KDAL sees inHg and statute miles, and the same build shows hPa and
/// metres at EDDF — without anyone touching Settings. The explicit cases pin
/// one convention everywhere, for pilots who would rather read one set of
/// units regardless of where they are flying.
///
/// Backed by the `unitSystem` UserDefaults key, so `-unitSystem icao` as a
/// launch argument seeds it for screenshots exactly like the other demo args.
enum UnitSystemPreference: String, CaseIterable, Identifiable {
    case automatic
    case us
    case icao
    case metric

    static let defaultsKey = "unitSystem"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .us: "US (inHg, SM)"
        case .icao: "ICAO (hPa, metres)"
        case .metric: "Metric (hPa, km, m)"
        }
    }

    var detail: String? {
        switch self {
        case .automatic: "Follows the country you're viewing."
        case .us, .icao, .metric: nil
        }
    }

    /// Resolve to concrete units. `jurisdiction` is only consulted for
    /// `.automatic`.
    func preferences(for jurisdiction: Jurisdiction) -> UnitPreferences {
        switch self {
        case .automatic: jurisdiction.units
        case .us: .faa
        case .icao: .icao
        case .metric: .metric
        }
    }

    /// The current setting, defaulting to `.automatic` when unset or when the
    /// stored value came from a build that knew a case this one doesn't.
    static var current: UnitSystemPreference {
        UserDefaults.standard.string(forKey: defaultsKey)
            .flatMap(UnitSystemPreference.init(rawValue:)) ?? .automatic
    }

    /// Convenience for the common case: units for a given location.
    static func units(for jurisdiction: Jurisdiction) -> UnitPreferences {
        current.preferences(for: jurisdiction)
    }

    static func units(forStation station: ICAOIdentifier) -> UnitPreferences {
        units(for: .forIdentifier(station))
    }

    /// Units for screens that aren't about one specific place — the map ruler,
    /// navlog totals.
    ///
    /// `.automatic` has nothing to key off here, so it falls back to the
    /// device's region: the best available proxy for where the pilot is based.
    /// Without this, automatic mode would resolve to the generic ICAO defaults
    /// and quietly show hPa and metres to a US pilot on the map.
    static var ambient: UnitPreferences {
        current.preferences(for: deviceJurisdiction)
    }

    static var deviceJurisdiction: Jurisdiction {
        guard let region = Locale.current.region?.identifier, !region.isEmpty else {
            return .unknown
        }
        return .forCountry(region)
    }
}
