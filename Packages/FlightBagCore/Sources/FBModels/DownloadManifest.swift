import Foundation

/// Published by the backend (`/v1/manifest`); consumed by the app's
/// DownloadCenter to know what offline artifacts exist for a cycle,
/// which regions they cover, where to fetch them, and how to verify them.
public struct DownloadManifest: Codable, Sendable, Hashable {
    public var generatedAt: Date
    /// Cycle id ("2607") this manifest's `products` belong to.
    public var cycle: String
    /// Every region the backend can serve; the app's region picker renders
    /// from this list, so new coverage never requires an app update.
    public var regions: [Region]
    public var products: [DownloadProduct]
    /// Products for the next cycle when the FAA has published it early.
    public var nextCycleProducts: [DownloadProduct]
    /// Where each chart layer's tiles come from. Defaulted so a manifest
    /// written before chart sources existed still decodes — the app falls
    /// back to its built-in FAA descriptors when this is empty.
    public var chartSources: [ChartSource]

    public init(
        generatedAt: Date,
        cycle: String,
        regions: [Region] = [],
        products: [DownloadProduct],
        nextCycleProducts: [DownloadProduct] = [],
        chartSources: [ChartSource] = []
    ) {
        self.generatedAt = generatedAt
        self.cycle = cycle
        self.regions = regions
        self.products = products
        self.nextCycleProducts = nextCycleProducts
        self.chartSources = chartSources
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        cycle = try container.decode(String.self, forKey: .cycle)
        regions = try container.decodeIfPresent([Region].self, forKey: .regions) ?? []
        products = try container.decode([DownloadProduct].self, forKey: .products)
        nextCycleProducts = try container.decodeIfPresent([DownloadProduct].self, forKey: .nextCycleProducts) ?? []
        chartSources = try container.decodeIfPresent([ChartSource].self, forKey: .chartSources) ?? []
    }
}

public struct DownloadProduct: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var contentKind: ContentKind
    /// Who published this artifact. Travels with the product so the app can
    /// credit the source offline — several licences require attribution
    /// wherever the data is shown, and an EFB shows charts precisely when it
    /// cannot reach the manifest.
    public var authority: DataAuthority
    /// Display title, e.g. "San Antonio Sectional", "Texas Approach Plates".
    public var title: String
    public var cycle: String
    /// Ids of every `Region` this artifact serves. Shared artifacts (a
    /// sectional straddling several states) list all of them, letting the
    /// app dedupe downloads and reference-count deletions.
    public var regionIds: [String]
    public var url: URL
    public var sizeBytes: Int64
    /// Hex-encoded SHA-256 of the artifact for post-download verification.
    public var sha256: String
    /// When this artifact stops being current. nil means it expires with
    /// `cycle`; set explicitly for editions on longer cadences (56-day IFR
    /// enroute charts) so freshness badges stay honest across cycles.
    public var expirationDate: Date?

    public enum ContentKind: String, Codable, Sendable, CaseIterable {
        case aeroDatabase
        case plates
        case vfrSectional
        case ifrEnrouteLow
        case ifrEnrouteHigh
        case basemap
        case terrain

        /// Kinds a region download offers, in display order. `aeroDatabase`
        /// is not among them — it ships with the app's cycle rather than per
        /// region — and `terrain` is not published yet.
        public static let offeredPerRegion: [ContentKind] = [
            .vfrSectional, .ifrEnrouteLow, .ifrEnrouteHigh, .plates, .basemap,
        ]

        /// What to call this in the download UI. Lives on the model so the
        /// several screens offering the same kinds cannot drift apart.
        public var displayName: String {
            switch self {
            case .aeroDatabase: "Airport & Navigation Database"
            case .plates: "Terminal Procedures"
            case .vfrSectional: "VFR Sectionals"
            case .ifrEnrouteLow: "IFR Enroute Low"
            case .ifrEnrouteHigh: "IFR Enroute High"
            case .basemap: "Offline Basemap"
            case .terrain: "Terrain"
            }
        }
    }

    public init(
        id: String,
        contentKind: ContentKind,
        authority: DataAuthority = .faa,
        title: String,
        cycle: String,
        regionIds: [String] = [],
        url: URL,
        sizeBytes: Int64,
        sha256: String,
        expirationDate: Date? = nil
    ) {
        self.id = id
        self.contentKind = contentKind
        self.authority = authority
        self.title = title
        self.cycle = cycle
        self.regionIds = regionIds
        self.url = url
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.expirationDate = expirationDate
    }

    /// Products published before `authority` existed decode as FAA, which is
    /// what every one of them was.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        contentKind = try container.decode(ContentKind.self, forKey: .contentKind)
        authority = try container.decodeIfPresent(DataAuthority.self, forKey: .authority) ?? .faa
        title = try container.decode(String.self, forKey: .title)
        cycle = try container.decode(String.self, forKey: .cycle)
        regionIds = try container.decodeIfPresent([String].self, forKey: .regionIds) ?? []
        url = try container.decode(URL.self, forKey: .url)
        sizeBytes = try container.decode(Int64.self, forKey: .sizeBytes)
        sha256 = try container.decode(String.self, forKey: .sha256)
        expirationDate = try container.decodeIfPresent(Date.self, forKey: .expirationDate)
    }
}
