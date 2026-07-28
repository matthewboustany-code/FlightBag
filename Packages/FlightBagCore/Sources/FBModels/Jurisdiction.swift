import Foundation

/// Which regulator's rules and conventions apply at a location.
///
/// This is deliberately *not* `DataAuthority`. That answers "who published
/// this row" (provenance, attribution, freshness); this answers "whose rules
/// does a pilot here fly under" (units, transition altitude, whether US
/// flight categories mean anything). The two diverge constantly once data
/// stops being FAA-only: OurAirports is the authority for a German aerodrome,
/// but EASA is its jurisdiction.
public enum RuleSet: String, Codable, Sendable, CaseIterable, Hashable {
    case faa
    case tcca
    case easa
    /// Generic ICAO conventions — the fallback for everywhere not called out.
    case icao
    /// States publishing altitudes and levels in metres.
    case icaoMetric

    public var defaultUnits: UnitPreferences {
        switch self {
        case .faa: .faa
        case .tcca: UnitPreferences(
            altimeter: .inchesOfMercury,
            distance: .nauticalMiles,
            visibility: .statuteMiles,
            altitude: .feet,
            speed: .knots
        )
        case .easa, .icao: .icao
        case .icaoMetric: .metric
        }
    }

    /// A single national transition altitude, where one exists.
    ///
    /// nil means it varies by aerodrome and must be read off the chart —
    /// which is the case across most of Europe. Returning nil rather than a
    /// plausible-looking default is the point: a wrong transition altitude is
    /// worse than an absent one.
    public var fixedTransitionAltitudeFeet: Int? {
        switch self {
        case .faa, .tcca: 18_000
        case .easa, .icao, .icaoMetric: nil
        }
    }

    /// VFR/MVFR/IFR/LIFR are FAA definitions. Other states have their own
    /// VMC/IMC minima, so the category badge is meaningless — and misleading —
    /// outside US airspace.
    ///
    /// Delegates to `Capability` so there is one place that decides.
    public var usesFlightCategories: Bool {
        supports(.flightCategories)
    }
}

/// A location's country and the rules that apply there.
public struct Jurisdiction: Codable, Sendable, Hashable {
    /// ISO 3166-1 alpha-2, e.g. "US", "DE". nil when it could not be resolved.
    public var countryCode: String?
    public var ruleSet: RuleSet

    public init(countryCode: String?, ruleSet: RuleSet) {
        self.countryCode = countryCode
        self.ruleSet = ruleSet
    }

    /// Used wherever nothing better is known.
    public static let unknown = Jurisdiction(countryCode: nil, ruleSet: .icao)

    public var units: UnitPreferences { ruleSet.defaultUnits }

    /// Resolve from an ISO 3166-1 alpha-2 country code — the preferred path,
    /// since `Airport.country` and OurAirports' `iso_country` both carry one.
    public static func forCountry(_ code: String) -> Jurisdiction {
        let upper = code.uppercased()
        return Jurisdiction(countryCode: upper, ruleSet: ruleSet(forCountry: upper))
    }

    /// Resolve from an ICAO location indicator when no database row is at hand
    /// — a typed flight-plan aerodrome, or a weather station we have no
    /// airport record for. Prefer `forCountry(_:)` whenever a record exists.
    public static func forIdentifier(_ identifier: ICAOIdentifier) -> Jurisdiction {
        let raw = identifier.rawValue
        guard raw.count == 4 else { return .unknown }

        if let country = countryForICAOPrefix(String(raw.prefix(2))) {
            return .forCountry(country)
        }
        if let country = countryForICAOPrefix(String(raw.prefix(1))) {
            return .forCountry(country)
        }
        return .unknown
    }

    static func countryForICAOPrefix(_ prefix: String) -> String? {
        icaoPrefixCountries[prefix]
    }

    static func ruleSet(forCountry code: String) -> RuleSet {
        if code == "US" { return .faa }
        if code == "CA" { return .tcca }
        if easaStates.contains(code) { return .easa }
        if metricLevelStates.contains(code) { return .icaoMetric }
        return .icao
    }

    /// EASA member states — EU plus Iceland, Liechtenstein, Norway,
    /// Switzerland. The UK left EASA in 2021 but kept the same conventions,
    /// so for units and transition-altitude purposes it belongs here.
    static let easaStates: Set<String> = [
        "AT", "BE", "BG", "CH", "CY", "CZ", "DE", "DK", "EE", "ES", "FI",
        "FR", "GB", "GR", "HR", "HU", "IE", "IS", "IT", "LI", "LT", "LU",
        "LV", "MT", "NL", "NO", "PL", "PT", "RO", "SE", "SI", "SK",
    ]

    /// States that publish altitudes and flight levels in metres. Russia is
    /// deliberately absent: it moved to feet for flight levels in 2011.
    static let metricLevelStates: Set<String> = ["CN", "KP", "MN"]

    /// ICAO location-indicator prefix → ISO 3166-1 alpha-2.
    ///
    /// Two-letter entries are checked first, then single-letter fallbacks for
    /// the countries that own an entire first letter. This is data, not logic
    /// — correct entries here rather than adding special cases elsewhere.
    static let icaoPrefixCountries: [String: String] = [
        // Single-letter blocks. Checked only after a two-letter miss, so the
        // exceptions below (ZK, ZM, UA, UK, …) still resolve correctly.
        "C": "CA", "K": "US", "Y": "AU", "Z": "CN", "U": "RU",

        // A — Southwest Pacific
        "AG": "SB", "AN": "NR", "AY": "PG",
        // B — North Atlantic
        "BG": "GL", "BI": "IS", "BK": "XK",
        // D — West Africa
        "DA": "DZ", "DB": "BJ", "DF": "BF", "DG": "GH", "DI": "CI",
        "DN": "NG", "DR": "NE", "DT": "TN", "DX": "TG",
        // E — Northern Europe
        "EB": "BE", "ED": "DE", "EE": "EE", "EF": "FI", "EG": "GB",
        "EH": "NL", "EI": "IE", "EK": "DK", "EL": "LU", "EN": "NO",
        "EP": "PL", "ES": "SE", "ET": "DE", "EV": "LV", "EY": "LT",
        // F — Southern Africa
        "FA": "ZA", "FB": "BW", "FC": "CG", "FD": "SZ", "FE": "CF",
        "FG": "GQ", "FI": "MU", "FK": "CM", "FL": "ZM", "FM": "MG",
        "FN": "AO", "FO": "GA", "FP": "ST", "FQ": "MZ", "FS": "SC",
        "FT": "TD", "FV": "ZW", "FW": "MW", "FX": "LS", "FY": "NA",
        "FZ": "CD",
        // G — Northwest Africa
        "GA": "ML", "GB": "GM", "GC": "ES", "GE": "ES", "GF": "SL",
        "GG": "GW", "GL": "LR", "GM": "MA", "GO": "SN", "GQ": "MR",
        "GS": "EH", "GU": "GN", "GV": "CV",
        // H — East Africa
        "HA": "ET", "HB": "BI", "HC": "SO", "HD": "DJ", "HE": "EG",
        "HH": "ER", "HK": "KE", "HL": "LY", "HR": "RW", "HS": "SD",
        "HT": "TZ", "HU": "UG",
        // L — Southern Europe
        "LA": "AL", "LB": "BG", "LC": "CY", "LD": "HR", "LE": "ES",
        "LF": "FR", "LG": "GR", "LH": "HU", "LI": "IT", "LJ": "SI",
        "LK": "CZ", "LL": "IL", "LM": "MT", "LN": "MC", "LO": "AT",
        "LP": "PT", "LQ": "BA", "LR": "RO", "LS": "CH", "LT": "TR",
        "LU": "MD", "LV": "PS", "LW": "MK", "LX": "GI", "LY": "RS",
        "LZ": "SK",
        // M — Mexico, Central America, Caribbean
        "MB": "TC", "MD": "DO", "MG": "GT", "MH": "HN", "MK": "JM",
        "MM": "MX", "MN": "NI", "MP": "PA", "MR": "CR", "MS": "SV",
        "MT": "HT", "MU": "CU", "MW": "KY", "MY": "BS", "MZ": "BZ",
        // N — South Pacific
        "NC": "CK", "NF": "FJ", "NG": "KI", "NI": "NU", "NL": "WF",
        "NS": "WS", "NT": "PF", "NV": "VU", "NW": "NC", "NZ": "NZ",
        // O — Middle East and Southwest Asia
        "OA": "AF", "OB": "BH", "OE": "SA", "OI": "IR", "OJ": "JO",
        "OK": "KW", "OL": "LB", "OM": "AE", "OO": "OM", "OP": "PK",
        "OR": "IQ", "OS": "SY", "OT": "QA", "OY": "YE",
        // P — Eastern Pacific (US outlying areas plus neighbours)
        "PA": "US", "PF": "US", "PG": "GU", "PH": "US", "PJ": "US",
        "PK": "MH", "PL": "KI", "PM": "US", "PO": "US", "PP": "US",
        "PT": "FM", "PW": "US",
        // R — East Asia
        "RC": "TW", "RJ": "JP", "RK": "KR", "RO": "JP", "RP": "PH",
        // S — South America
        "SA": "AR", "SB": "BR", "SC": "CL", "SD": "BR", "SE": "EC",
        "SF": "FK", "SG": "PY", "SI": "BR", "SJ": "BR", "SK": "CO",
        "SL": "BO", "SM": "SR", "SN": "BR", "SO": "GF", "SP": "PE",
        "SS": "BR", "SU": "UY", "SV": "VE", "SW": "BR", "SY": "GY",
        // T — Caribbean
        "TA": "AG", "TB": "BB", "TD": "DM", "TF": "GP", "TG": "GD",
        "TI": "VI", "TJ": "PR", "TK": "KN", "TL": "LC", "TN": "CW",
        "TQ": "AI", "TR": "MS", "TT": "TT", "TU": "VG", "TV": "VC",
        "TX": "BM",
        // U — Russia and post-Soviet states
        "UA": "KZ", "UB": "AZ", "UC": "KG", "UD": "AM", "UG": "GE",
        "UK": "UA", "UM": "BY", "UT": "UZ",
        // V — South and Southeast Asia
        "VA": "IN", "VC": "LK", "VD": "KH", "VE": "IN", "VG": "BD",
        "VH": "HK", "VI": "IN", "VL": "LA", "VM": "MO", "VN": "NP",
        "VO": "IN", "VQ": "BT", "VR": "MV", "VT": "TH", "VV": "VN",
        "VY": "MM",
        // W — Maritime Southeast Asia
        "WA": "ID", "WB": "MY", "WI": "ID", "WM": "MY", "WP": "TL",
        "WQ": "ID", "WR": "ID", "WS": "SG",
        // Z — China, Mongolia, DPRK
        "ZK": "KP", "ZM": "MN",
    ]
}

extension Jurisdiction {
    /// Resolve for an airport, preferring its country code and falling back to
    /// its identifier.
    public static func forAirport(country: String?, identifier: ICAOIdentifier?) -> Jurisdiction {
        if let country, !country.isEmpty {
            return .forCountry(country)
        }
        if let identifier {
            return .forIdentifier(identifier)
        }
        return .unknown
    }
}
