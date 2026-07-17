import Foundation
import FBModels

/// Hand-curated catalog of downloadable regions and which FAA chart files
/// cover them. This is data, not logic: the manifest builder bakes it into
/// `DownloadManifest.regions` / `DownloadProduct.regionIds`, so the app never
/// ships a mapping and coverage fixes are a server-side edit.
///
/// State coverage is deliberately generous — a state lists every sectional
/// that meaningfully touches it — and approximate at chart edges; correct it
/// here as users report gaps.
enum ChartCatalog {
    // MARK: Regions

    static let regions: [Region] = usStateNames
        .map { code, name in
            Region(id: "US-\(code)", name: name, authority: .faa, kind: .stateOrProvince)
        }
        .sorted { $0.name < $1.name }

    static var regionIds: [String] { regions.map(\.id) }

    static func region(id: String) -> Region? {
        regions.first { $0.id == id }
    }

    // MARK: Tiled charts

    struct TiledChart {
        /// FAA chart file base name as used in artifact filenames, e.g.
        /// "San_Antonio" → `San_Antonio_sectional.mbtiles`.
        let fileName: String
        let contentKind: DownloadProduct.ContentKind
        /// Region ids (state codes) the chart covers.
        let regionIds: [String]
    }

    /// Region ids for a produced tile artifact filename
    /// ("San_Antonio_sectional.mbtiles"), or nil if the chart is unknown.
    static func regionIds(forTileArtifact fileName: String) -> [String]? {
        for (suffix, _) in Self.tileSuffixKinds {
            if fileName.hasSuffix(suffix) {
                let base = String(fileName.dropLast(suffix.count))
                return tiledCharts.first { $0.fileName == base }?.regionIds
            }
        }
        return nil
    }

    /// Filename-suffix → content-kind convention every tile pipeline output
    /// must follow (see ChartKind.kind(forFileName:) on the app side).
    static let tileSuffixKinds: [(suffix: String, kind: DownloadProduct.ContentKind)] = [
        ("_sectional.mbtiles", .vfrSectional),
        ("_ifr_low.mbtiles", .ifrEnrouteLow),
        ("_ifr_high.mbtiles", .ifrEnrouteHigh),
    ]

    static var tiledCharts: [TiledChart] {
        vfrSectionals
        // IFR enroute panels join here in the enroute-pipeline milestone.
    }

    /// CONUS + Alaska + Hawaii VFR sectionals with the states each covers.
    static let vfrSectionals: [TiledChart] = [
        sectional("Albuquerque", ["NM", "AZ", "CO", "TX"]),
        sectional("Atlanta", ["GA", "AL", "TN", "SC", "NC"]),
        sectional("Billings", ["MT", "WY", "ND", "SD"]),
        sectional("Brownsville", ["TX"]),
        sectional("Charlotte", ["NC", "SC", "VA", "TN", "GA"]),
        sectional("Cheyenne", ["WY", "NE", "CO", "SD"]),
        sectional("Chicago", ["IL", "IN", "WI", "MI", "IA"]),
        sectional("Cincinnati", ["OH", "KY", "IN", "WV", "VA", "TN"]),
        sectional("Dallas-Ft_Worth", ["TX", "OK", "AR", "LA"]),
        sectional("Denver", ["CO", "KS", "NE", "WY", "UT"]),
        sectional("Detroit", ["MI", "OH", "IN", "PA", "NY"]),
        sectional("El_Paso", ["TX", "NM", "AZ"]),
        sectional("Great_Falls", ["MT", "ID"]),
        sectional("Green_Bay", ["WI", "MI"]),
        sectional("Halifax", ["ME"]),
        sectional("Houston", ["TX", "LA"]),
        sectional("Jacksonville", ["FL", "GA", "SC", "AL"]),
        sectional("Kansas_City", ["MO", "KS", "IA", "NE", "IL"]),
        sectional("Klamath_Falls", ["OR", "CA", "NV"]),
        sectional("Lake_Huron", ["MI"]),
        sectional("Las_Vegas", ["NV", "AZ", "UT", "CA"]),
        sectional("Los_Angeles", ["CA"]),
        sectional("Memphis", ["TN", "AR", "MS", "MO", "KY", "AL"]),
        sectional("Miami", ["FL"]),
        sectional("Montreal", ["NY", "VT", "NH", "ME"]),
        sectional("New_Orleans", ["LA", "MS", "AL", "FL"]),
        sectional("New_York", ["NY", "NJ", "PA", "CT", "RI", "MA", "VT", "NH"]),
        sectional("Omaha", ["NE", "IA", "SD", "MN", "MO"]),
        sectional("Phoenix", ["AZ", "NM"]),
        sectional("Salt_Lake_City", ["UT", "ID", "WY", "NV"]),
        sectional("San_Antonio", ["TX"]),
        sectional("San_Francisco", ["CA", "NV"]),
        sectional("Seattle", ["WA", "OR", "ID"]),
        sectional("St_Louis", ["MO", "IL", "IN", "KY", "TN", "AR"]),
        sectional("Twin_Cities", ["MN", "WI", "ND", "SD", "IA", "MI"]),
        sectional("Washington", ["DC", "MD", "VA", "WV", "PA", "NJ", "DE", "NC"]),
        sectional("Wichita", ["KS", "OK", "TX", "MO"]),
        // Alaska
        sectional("Anchorage", ["AK"]),
        sectional("Bethel", ["AK"]),
        sectional("Cape_Lisburne", ["AK"]),
        sectional("Cold_Bay", ["AK"]),
        sectional("Dawson", ["AK"]),
        sectional("Dutch_Harbor", ["AK"]),
        sectional("Fairbanks", ["AK"]),
        sectional("Juneau", ["AK"]),
        sectional("Ketchikan", ["AK"]),
        sectional("Kodiak", ["AK"]),
        sectional("McGrath", ["AK"]),
        sectional("Nome", ["AK"]),
        sectional("Point_Barrow", ["AK"]),
        sectional("Seward", ["AK"]),
        sectional("Western_Aleutian_Islands", ["AK"]),
        // Hawaii
        sectional("Hawaiian_Islands", ["HI"]),
    ]

    private static func sectional(_ fileName: String, _ states: [String]) -> TiledChart {
        TiledChart(
            fileName: fileName,
            contentKind: .vfrSectional,
            regionIds: states.map { "US-\($0)" }
        )
    }

    // MARK: State names

    private static let usStateNames: [(String, String)] = [
        ("AL", "Alabama"), ("AK", "Alaska"), ("AZ", "Arizona"), ("AR", "Arkansas"),
        ("CA", "California"), ("CO", "Colorado"), ("CT", "Connecticut"),
        ("DE", "Delaware"), ("DC", "District of Columbia"), ("FL", "Florida"),
        ("GA", "Georgia"), ("HI", "Hawaii"), ("ID", "Idaho"), ("IL", "Illinois"),
        ("IN", "Indiana"), ("IA", "Iowa"), ("KS", "Kansas"), ("KY", "Kentucky"),
        ("LA", "Louisiana"), ("ME", "Maine"), ("MD", "Maryland"),
        ("MA", "Massachusetts"), ("MI", "Michigan"), ("MN", "Minnesota"),
        ("MS", "Mississippi"), ("MO", "Missouri"), ("MT", "Montana"),
        ("NE", "Nebraska"), ("NV", "Nevada"), ("NH", "New Hampshire"),
        ("NJ", "New Jersey"), ("NM", "New Mexico"), ("NY", "New York"),
        ("NC", "North Carolina"), ("ND", "North Dakota"), ("OH", "Ohio"),
        ("OK", "Oklahoma"), ("OR", "Oregon"), ("PA", "Pennsylvania"),
        ("RI", "Rhode Island"), ("SC", "South Carolina"), ("SD", "South Dakota"),
        ("TN", "Tennessee"), ("TX", "Texas"), ("UT", "Utah"), ("VT", "Vermont"),
        ("VA", "Virginia"), ("WA", "Washington"), ("WV", "West Virginia"),
        ("WI", "Wisconsin"), ("WY", "Wyoming"),
    ]
}
