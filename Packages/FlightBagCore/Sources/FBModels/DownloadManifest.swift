import Foundation

/// Published by the backend (`/v1/manifest`); consumed by the app's
/// DownloadManager to know what offline artifacts exist for a cycle,
/// where to fetch them, and how to verify them.
public struct DownloadManifest: Codable, Sendable, Hashable {
    public var generatedAt: Date
    /// Cycle id ("2607") this manifest's `products` belong to.
    public var cycle: String
    /// Products for the next cycle when the FAA has published it early.
    public var products: [DownloadProduct]
    public var nextCycleProducts: [DownloadProduct]

    public init(generatedAt: Date, cycle: String, products: [DownloadProduct], nextCycleProducts: [DownloadProduct] = []) {
        self.generatedAt = generatedAt
        self.cycle = cycle
        self.products = products
        self.nextCycleProducts = nextCycleProducts
    }
}

public struct DownloadProduct: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: Kind
    /// Display title, e.g. "Airport & Navigation Database", "Texas Approach Plates".
    public var title: String
    public var cycle: String
    public var url: URL
    public var sizeBytes: Int64
    /// Hex-encoded SHA-256 of the artifact for post-download verification.
    public var sha256: String

    public enum Kind: String, Codable, Sendable {
        case aeroDatabase
        case plates
        case chartTiles
        case terrain
    }

    public init(id: String, kind: Kind, title: String, cycle: String, url: URL, sizeBytes: Int64, sha256: String) {
        self.id = id
        self.kind = kind
        self.title = title
        self.cycle = cycle
        self.url = url
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
    }
}
