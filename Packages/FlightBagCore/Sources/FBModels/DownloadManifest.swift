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

    public init(
        generatedAt: Date,
        cycle: String,
        regions: [Region] = [],
        products: [DownloadProduct],
        nextCycleProducts: [DownloadProduct] = []
    ) {
        self.generatedAt = generatedAt
        self.cycle = cycle
        self.regions = regions
        self.products = products
        self.nextCycleProducts = nextCycleProducts
    }
}

public struct DownloadProduct: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var contentKind: ContentKind
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
    }

    public init(
        id: String,
        contentKind: ContentKind,
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
        self.title = title
        self.cycle = cycle
        self.regionIds = regionIds
        self.url = url
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.expirationDate = expirationDate
    }
}
