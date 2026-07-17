import Foundation
import Testing
import FBModels
@testable import App

@Suite struct ManifestBuilderTests {
    /// Builds a scratch artifact tree and returns (root, builder).
    private func makeTree() throws -> (URL, ManifestBuilder) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let builder = ManifestBuilder(
            artifactsRoot: root,
            baseURL: URL(string: "http://127.0.0.1:8080")!,
            logger: { _ in }
        )
        return (root, builder)
    }

    private func write(_ content: String, to root: URL, path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func buildsProductsFromArtifactTree() throws {
        let (root, builder) = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let cycle = DataCycle.current()

        try write("tile-bytes", to: root, path: "\(cycle.id)/tiles/San_Antonio_sectional.mbtiles")
        try write("plate-bytes", to: root, path: "\(cycle.id)/plates/plates_US-TX_\(cycle.id).zip")
        try write("db-bytes", to: root, path: "\(cycle.id)/db/aero.sqlite")

        let manifest = try builder.build(currentCycle: cycle)

        #expect(manifest.cycle == cycle.id)
        #expect(!manifest.regions.isEmpty)
        #expect(manifest.regions.contains { $0.id == "US-TX" && $0.name == "Texas" })
        #expect(manifest.products.count == 3)

        let sectional = try #require(manifest.products.first { $0.contentKind == .vfrSectional })
        #expect(sectional.title == "San Antonio Sectional")
        #expect(sectional.regionIds == ["US-TX"])
        #expect(sectional.cycle == cycle.id)
        #expect(sectional.sizeBytes == Int64("tile-bytes".utf8.count))
        #expect(sectional.url.absoluteString == "http://127.0.0.1:8080/artifacts/\(cycle.id)/tiles/San_Antonio_sectional.mbtiles")
        #expect(sectional.expirationDate == nil)

        let plates = try #require(manifest.products.first { $0.contentKind == .plates })
        #expect(plates.regionIds == ["US-TX"])
        #expect(plates.title == "Texas Terminal Procedures")

        let db = try #require(manifest.products.first { $0.contentKind == .aeroDatabase })
        #expect(db.regionIds.count == manifest.regions.count)
    }

    @Test func sha256MatchesAndIsCachedInSidecar() throws {
        let (root, builder) = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let cycle = DataCycle.current()

        try write("abc", to: root, path: "\(cycle.id)/tiles/Miami_sectional.mbtiles")
        let manifest = try builder.build(currentCycle: cycle)
        let product = try #require(manifest.products.first)
        // SHA-256("abc")
        #expect(product.sha256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

        let sidecar = root.appendingPathComponent("\(cycle.id)/tiles/Miami_sectional.mbtiles.sha256")
        #expect(FileManager.default.fileExists(atPath: sidecar.path))
        // A second build reuses the sidecar (same hash back out).
        #expect(try builder.build(currentCycle: cycle).products.first?.sha256 == product.sha256)
    }

    @Test func carriesForwardUnexpiredPreviousCycleArtifacts() throws {
        let (root, builder) = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let cycle = DataCycle.current()
        let previous = cycle.previous()

        // Unexpired IFR chart from last cycle: carried forward.
        try write("low-bytes", to: root, path: "\(previous.id)/tiles/ELUS01_ifr_low.mbtiles")
        let future = ISO8601DateFormatter().string(from: Date().addingTimeInterval(20 * 86_400))
        try write(future, to: root, path: "\(previous.id)/tiles/ELUS01_ifr_low.mbtiles.expires")

        // Expired sibling: dropped.
        try write("high-bytes", to: root, path: "\(previous.id)/tiles/EHUS01_ifr_high.mbtiles")
        let past = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-86_400))
        try write(past, to: root, path: "\(previous.id)/tiles/EHUS01_ifr_high.mbtiles.expires")

        // Re-published in the current cycle: current copy wins, no duplicate.
        try write("low2-old", to: root, path: "\(previous.id)/tiles/ELUS02_ifr_low.mbtiles")
        try write(future, to: root, path: "\(previous.id)/tiles/ELUS02_ifr_low.mbtiles.expires")
        try write("low2-new", to: root, path: "\(cycle.id)/tiles/ELUS02_ifr_low.mbtiles")

        let manifest = try builder.build(currentCycle: cycle)
        let names = manifest.products.map { $0.url.lastPathComponent }
        #expect(names.sorted() == ["ELUS01_ifr_low.mbtiles", "ELUS02_ifr_low.mbtiles"])
        let carried = try #require(manifest.products.first { $0.url.lastPathComponent == "ELUS01_ifr_low.mbtiles" })
        #expect(carried.cycle == previous.id)
        #expect(carried.expirationDate != nil)
        let republished = try #require(manifest.products.first { $0.url.lastPathComponent == "ELUS02_ifr_low.mbtiles" })
        #expect(republished.cycle == cycle.id)
    }

    @Test func nextCyclePublishesEarly() throws {
        let (root, builder) = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let cycle = DataCycle.current()

        try write("next-bytes", to: root, path: "\(cycle.next().id)/tiles/Denver_sectional.mbtiles")
        let manifest = try builder.build(currentCycle: cycle)
        #expect(manifest.products.isEmpty)
        #expect(manifest.nextCycleProducts.count == 1)
        #expect(manifest.nextCycleProducts.first?.cycle == cycle.next().id)
    }

    @Test func skipsSidecarsAndUnknownFiles() throws {
        let (root, builder) = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let cycle = DataCycle.current()

        try write("bytes", to: root, path: "\(cycle.id)/tiles/README.txt")
        try write("bytes", to: root, path: "\(cycle.id)/tiles/orphan.sha256")
        try write("basemap-bytes", to: root, path: "\(cycle.id)/basemap/basemap_us_z0-8.mbtiles")

        let manifest = try builder.build(currentCycle: cycle)
        #expect(manifest.products.count == 1)
        let basemap = try #require(manifest.products.first)
        #expect(basemap.contentKind == .basemap)
        #expect(basemap.regionIds.count == manifest.regions.count)
    }
}
