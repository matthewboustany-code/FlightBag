import Foundation
import Testing
import FBModels
@testable import FlightBag

@Suite struct ZipExtractorTests {
    /// zip -r -X of {AUS/00048il18l.pdf (deflated), PVD/00341il5.pdf (stored)}.
    private static let fixtureBase64 = "UEsDBAoAAAAAAGRQ8VwAAAAAAAAAAAAAAAAEAAAAQVVTL1BLAwQUAAAACABkUPFcobCk+yoAAAA+AAAAEgAAAEFVUy8wMDA0OGlsMThsLnBkZstIzcnJV0gsLS7JzFMoyEksSVUoSElTSM7PK0nNK1EoSExJycxLx0UDAFBLAwQKAAAAAABkUPFcAAAAAAAAAAAAAAAABAAAAFBWRC9QSwMECgAAAAAAZFDxXIMW3IwBAAAAAQAAABAAAABQVkQvMDAzNDFpbDUucGRmeFBLAQIeAwoAAAAAAGRQ8VwAAAAAAAAAAAAAAAAEAAAAAAAAAAAAEADtQQAAAABBVVMvUEsBAh4DFAAAAAgAZFDxXKGwpPsqAAAAPgAAABIAAAAAAAAAAQAAAKSBIgAAAEFVUy8wMDA0OGlsMThsLnBkZlBLAQIeAwoAAAAAAGRQ8VwAAAAAAAAAAAAAAAAEAAAAAAAAAAAAEADtQXwAAABQVkQvUEsBAh4DCgAAAAAAZFDxXIMW3IwBAAAAAQAAABAAAAAAAAAAAQAAAKSBngAAAFBWRC8wMDM0MWlsNS5wZGZQSwUGAAAAAAQABADiAAAAzQAAAAAA"

    private func scratchDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zip-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func extractsStoredAndDeflatedEntries() throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let zipURL = dir.appendingPathComponent("fixture.zip")
        try Data(base64Encoded: Self.fixtureBase64)!.write(to: zipURL)

        let destination = dir.appendingPathComponent("out", isDirectory: true)
        let topLevel = try ZipExtractor.extract(zipAt: zipURL, to: destination)

        // Airport-id dirs reported for refcounted delete.
        #expect(topLevel == ["AUS", "PVD"])
        let deflated = try String(contentsOf: destination.appendingPathComponent("AUS/00048il18l.pdf"), encoding: .utf8)
        #expect(deflated == "hello austin plate pdf content padding padding padding padding")
        let stored = try String(contentsOf: destination.appendingPathComponent("PVD/00341il5.pdf"), encoding: .utf8)
        #expect(stored == "x")
    }

    @Test func rejectsGarbage() throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bogus = dir.appendingPathComponent("bogus.zip")
        try Data("not a zip at all".utf8).write(to: bogus)
        #expect(throws: ZipExtractor.ZipError.self) {
            try ZipExtractor.extract(zipAt: bogus, to: dir.appendingPathComponent("out"))
        }
    }

    @Test func rejectsPathTraversal() throws {
        // Handcraft a zip whose single entry is named "../evil.txt" by
        // rewriting the fixture is overkill — instead assert the guard via
        // the public API contract: any entry containing ".." must throw.
        // (Covered structurally: ZipExtractor.extract throws ZipError for
        // unsafe paths; this test documents the contract with a crafted zip.)
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let zipURL = dir.appendingPathComponent("evil.zip")
        try Self.makeSingleEntryZip(named: "../evil.txt", contents: Data("boom".utf8)).write(to: zipURL)
        #expect(throws: ZipExtractor.ZipError.self) {
            try ZipExtractor.extract(zipAt: zipURL, to: dir.appendingPathComponent("out"))
        }
    }

    /// Builds a minimal stored-entry zip in memory (local header + central
    /// directory + EOCD) for adversarial-name tests.
    private static func makeSingleEntryZip(named name: String, contents: Data) -> Data {
        let nameBytes = Data(name.utf8)
        let crc = crc32(contents)
        var local = Data()
        local.append(le32(0x04034b50)); local.append(le16(20)); local.append(le16(0))
        local.append(le16(0))  // stored
        local.append(le16(0)); local.append(le16(0))
        local.append(le32(crc)); local.append(le32(UInt32(contents.count))); local.append(le32(UInt32(contents.count)))
        local.append(le16(UInt16(nameBytes.count))); local.append(le16(0))
        local.append(nameBytes); local.append(contents)

        var central = Data()
        central.append(le32(0x02014b50)); central.append(le16(20)); central.append(le16(20)); central.append(le16(0))
        central.append(le16(0))  // stored
        central.append(le16(0)); central.append(le16(0))
        central.append(le32(crc)); central.append(le32(UInt32(contents.count))); central.append(le32(UInt32(contents.count)))
        central.append(le16(UInt16(nameBytes.count))); central.append(le16(0)); central.append(le16(0))
        central.append(le16(0)); central.append(le16(0)); central.append(le32(0))
        central.append(le32(0))  // local header offset
        central.append(nameBytes)

        var eocd = Data()
        eocd.append(le32(0x06054b50)); eocd.append(le16(0)); eocd.append(le16(0))
        eocd.append(le16(1)); eocd.append(le16(1))
        eocd.append(le32(UInt32(central.count))); eocd.append(le32(UInt32(local.count)))
        eocd.append(le16(0))
        return local + central + eocd
    }

    private static func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private static func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1)))
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

@Suite struct DownloadVerificationTests {
    @Test func streamingSHA256MatchesKnownDigest() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sha-test-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)
        let digest = try DownloadCenter.streamingSHA256(of: url)
        #expect(digest == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func productIdsFlattenToSafeFileNames() {
        #expect(DownloadService.fileSafe("2607/tiles/San_Antonio_sectional.mbtiles")
            == "2607_tiles_San_Antonio_sectional.mbtiles")
    }
}

/// Serialized: each test owns a background URLSession, and iOS allows only
/// one live session per identifier.
@MainActor
@Suite(.serialized) struct DownloadCenterRelaunchTests {
    private func scratchRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-center-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func product(sha256: String) -> DownloadProduct {
        DownloadProduct(
            id: "2609/db/aero.sqlite", contentKind: .aeroDatabase, title: "Database", cycle: "2609",
            regionIds: ["US-TX"], url: URL(string: "https://example.invalid/aero.sqlite")!,
            sizeBytes: 3, sha256: sha256
        )
    }

    /// Writes the state.json a previous launch would have left mid-transfer.
    private func writeInFlightState(_ product: DownloadProduct, root: URL) throws {
        let json: [String: Any] = [
            "records": [], "installed": [:],
            "inFlightProducts": [product.id: try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(product))],
        ]
        let stateURL = root.appendingPathComponent("FlightBag/downloads/state.json")
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json).write(to: stateURL)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func transferFinishingBeforeAnyManifestStillInstalls() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let staged = root.appendingPathComponent("staged.bin")
        try Data("abc".utf8).write(to: staged)
        let product = product(sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        try writeInFlightState(product, root: root)

        // Relaunched for background session events: nothing has fetched a
        // manifest, and the cached one (if any) predates this product.
        let center = DownloadCenter(root: root, sessionIdentifier: "tests.\(UUID().uuidString)")
        center.finishForTesting(productId: product.id, staged: staged)
        await waitUntil { center.isInstalled(product.id) || center.phase(for: product.id).isFailure }

        #expect(center.phase(for: product.id) == .installed)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("FlightBag/cycles/2609/aero.sqlite").path))
    }

    @Test func lateProgressDoesNotRewindAFinishedProduct() throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let center = DownloadCenter(root: root, sessionIdentifier: "tests.\(UUID().uuidString)")
        let id = "2609/tiles/x.mbtiles"

        for phase in [DownloadCenter.Phase.verifying, .installing, .installed, .paused, .failed("x")] {
            center.setPhaseForTesting(phase, productId: id)
            center.progressForTesting(productId: id, fraction: 1)
            #expect(center.phase(for: id) == phase)
        }
        center.setPhaseForTesting(.queued, productId: id)
        center.progressForTesting(productId: id, fraction: 0.5)
        #expect(center.phase(for: id) == .downloading(0.5))
    }
}

private extension Optional where Wrapped == DownloadCenter.Phase {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

@MainActor
@Suite(.serialized) struct CycleRolloverTests {
    private func center() throws -> (DownloadCenter, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rollover-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (DownloadCenter(root: root, sessionIdentifier: "tests.\(UUID().uuidString)"), root)
    }

    private func product(_ name: String, cycle: String, kind: DownloadProduct.ContentKind = .vfrSectional,
                         regions: [String] = ["US-TX"]) -> DownloadProduct {
        DownloadProduct(
            id: "\(cycle)/tiles/\(name)", contentKind: kind, title: name, cycle: cycle, regionIds: regions,
            url: URL(string: "https://example.invalid/\(cycle)/\(name)")!, sizeBytes: 1, sha256: ""
        )
    }

    @Test func staleRecordRequeuesFromTheCurrentManifest() throws {
        let (center, root) = try center()
        defer { try? FileManager.default.removeItem(at: root) }
        let current = product("San_Antonio_sectional.mbtiles", cycle: "2610")
        let plates = product("plates_US-TX.zip", cycle: "2610", kind: .plates)
        center.setManifestForTesting(
            DownloadManifest(generatedAt: Date(), cycle: "2610", products: [current, plates]),
            records: [.init(regionId: "US-TX", kinds: [.vfrSectional], cycle: "2609")]
        )

        center.applyAutomaticUpdates(now: DataCycle(id: "2610")!.effectiveDate.addingTimeInterval(86_400))

        #expect(center.phase(for: current.id) == .queued)
        // Only the kinds the region keeps.
        #expect(center.phase(for: plates.id) == nil)
        #expect(center.records.first?.cycle == "2610")
    }

    @Test func nextCycleIsPreloadedInsideTheWindowOnly() throws {
        let next = DataCycle(id: "2611")!
        let upcoming = product("San_Antonio_sectional.mbtiles", cycle: "2611")
        let manifest = DownloadManifest(generatedAt: Date(), cycle: "2610", products: [], nextCycleProducts: [upcoming])
        let record = DownloadCenter.RegionDownloadRecord(regionId: "US-TX", kinds: [.vfrSectional], cycle: "2610")

        let (inside, rootA) = try center()
        defer { try? FileManager.default.removeItem(at: rootA) }
        inside.setManifestForTesting(manifest, records: [record])
        inside.applyAutomaticUpdates(now: next.effectiveDate.addingTimeInterval(-3 * 86_400))
        #expect(inside.phase(for: upcoming.id) == .queued)

        let (outside, rootB) = try center()
        defer { try? FileManager.default.removeItem(at: rootB) }
        outside.setManifestForTesting(manifest, records: [record])
        outside.applyAutomaticUpdates(now: next.effectiveDate.addingTimeInterval(-10 * 86_400))
        #expect(outside.phase(for: upcoming.id) == nil)
    }

    @Test func automaticPassLeavesPausedTransfersAlone() throws {
        let (center, root) = try center()
        defer { try? FileManager.default.removeItem(at: root) }
        let current = product("Houston_sectional.mbtiles", cycle: "2610")
        center.setManifestForTesting(
            DownloadManifest(generatedAt: Date(), cycle: "2610", products: [current]),
            records: [.init(regionId: "US-TX", kinds: [.vfrSectional], cycle: "2609")]
        )
        center.setPhaseForTesting(.paused, productId: current.id)
        center.applyAutomaticUpdates(now: DataCycle(id: "2610")!.effectiveDate)
        #expect(center.phase(for: current.id) == .paused)
    }
}
