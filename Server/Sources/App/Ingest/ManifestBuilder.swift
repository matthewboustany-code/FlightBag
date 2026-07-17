import Foundation
import Crypto
import FBModels

/// Turns the on-disk artifact tree into a `DownloadManifest`.
///
/// Expected layout (each path maps 1:1 onto an object-storage key later):
///
///     {artifactsRoot}/{cycle}/tiles/San_Antonio_sectional.mbtiles
///     {artifactsRoot}/{cycle}/tiles/ELUS01_ifr_low.mbtiles
///     {artifactsRoot}/{cycle}/plates/plates_US-TX_2607.zip
///     {artifactsRoot}/{cycle}/basemap/basemap_us_z0-8.mbtiles
///     {artifactsRoot}/{cycle}/db/aero.sqlite
///
/// Sidecars next to each artifact:
///   - `{file}.sha256` — cached "hash size mtime" so rebuilds don't re-hash
///     multi-hundred-MB files (recomputed when size/mtime change).
///   - `{file}.expires` — ISO8601 date for artifacts outliving their cycle
///     (56-day IFR enroute editions); written by the ingest pipeline.
///
/// Products come from the current cycle's directory, plus still-valid
/// carry-overs from the previous cycle (per `.expires`) that the current
/// cycle hasn't re-published, plus `nextCycleProducts` when the FAA has
/// published early.
struct ManifestBuilder {
    let artifactsRoot: URL
    /// Absolute base the manifest's product URLs are built from; artifact
    /// paths are appended as `artifacts/{cycle}/{category}/{file}`.
    let baseURL: URL
    let logger: (String) -> Void

    private static let artifactCategories = ["tiles", "plates", "basemap", "db"]

    func build(currentCycle: DataCycle, generatedAt: Date = Date()) throws -> DownloadManifest {
        var products = try scanProducts(inCycleDirectory: currentCycle.id)
        let publishedNames = Set(products.map { $0.url.lastPathComponent })

        // Carry forward unexpired longer-cadence artifacts (IFR enroute) from
        // the previous cycle unless the current cycle re-published them.
        for product in try scanProducts(inCycleDirectory: currentCycle.previous().id) {
            guard let expiration = product.expirationDate, expiration > generatedAt,
                  !publishedNames.contains(product.url.lastPathComponent) else { continue }
            products.append(product)
        }

        let nextCycleProducts = try scanProducts(inCycleDirectory: currentCycle.next().id)

        return DownloadManifest(
            generatedAt: generatedAt,
            cycle: currentCycle.id,
            regions: ChartCatalog.regions,
            products: products.sorted { $0.id < $1.id },
            nextCycleProducts: nextCycleProducts.sorted { $0.id < $1.id }
        )
    }

    // MARK: Directory scan

    private func scanProducts(inCycleDirectory cycleId: String) throws -> [DownloadProduct] {
        let fileManager = FileManager.default
        let cycleDir = artifactsRoot.appendingPathComponent(cycleId, isDirectory: true)
        guard fileManager.fileExists(atPath: cycleDir.path) else { return [] }

        var products: [DownloadProduct] = []
        for category in Self.artifactCategories {
            let dir = cycleDir.appendingPathComponent(category, isDirectory: true)
            guard let files = try? fileManager.contentsOfDirectory(atPath: dir.path) else { continue }
            for file in files.sorted() {
                guard !file.hasSuffix(".sha256"), !file.hasSuffix(".expires"), !file.hasPrefix(".") else { continue }
                let fileURL = dir.appendingPathComponent(file)
                if let product = try product(for: fileURL, category: category, cycleId: cycleId) {
                    products.append(product)
                }
            }
        }
        return products
    }

    private func product(for fileURL: URL, category: String, cycleId: String) throws -> DownloadProduct? {
        let file = fileURL.lastPathComponent
        guard let (contentKind, regionIds, title) = classify(file, at: fileURL) else {
            logger("Skipping unrecognized artifact \(cycleId)/\(category)/\(file)")
            return nil
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let sizeBytes = (attributes[.size] as? Int64) ?? 0
        let sha256 = try cachedSHA256(of: fileURL, sizeBytes: sizeBytes, attributes: attributes)

        return DownloadProduct(
            id: "\(cycleId)/\(category)/\(file)",
            contentKind: contentKind,
            title: title,
            cycle: cycleId,
            regionIds: regionIds,
            url: baseURL
                .appendingPathComponent("artifacts")
                .appendingPathComponent(cycleId)
                .appendingPathComponent(category)
                .appendingPathComponent(file),
            sizeBytes: sizeBytes,
            sha256: sha256,
            expirationDate: expirationDate(for: fileURL)
        )
    }

    /// (kind, regionIds, title) from the artifact filename conventions, or
    /// nil for files the manifest shouldn't publish.
    private func classify(_ file: String, at fileURL: URL) -> (DownloadProduct.ContentKind, [String], String)? {
        for (suffix, kind) in ChartCatalog.tileSuffixKinds where file.hasSuffix(suffix) {
            return (kind, tileRegionIds(file, at: fileURL), displayName(file))
        }
        if file.hasPrefix("plates_"), file.hasSuffix(".zip") {
            // plates_{regionId}_{cycle}.zip
            let parts = file.dropLast(4).split(separator: "_")
            guard parts.count >= 3 else { return nil }
            let regionId = String(parts[1])
            let regionName = ChartCatalog.region(id: regionId)?.name ?? regionId
            return (.plates, [regionId], "\(regionName) Terminal Procedures")
        }
        if file.hasPrefix("basemap"), file.hasSuffix(".mbtiles") {
            return (.basemap, ChartCatalog.regionIds, "Offline Basemap")
        }
        if file == "aero.sqlite" {
            return (.aeroDatabase, ChartCatalog.regionIds, "Airport & Navigation Database")
        }
        return nil
    }

    /// Coverage for a tile artifact: the MBTiles' own `bounds` metadata
    /// intersected with state boxes when readable (accurate and automatic),
    /// else the hand-curated catalog table.
    private func tileRegionIds(_ file: String, at fileURL: URL) -> [String] {
        if let bounds = RegionBounds.mbtilesBounds(at: fileURL) {
            let ids = RegionBounds.regionIds(intersecting: bounds)
            if !ids.isEmpty { return ids }
        }
        if let ids = ChartCatalog.regionIds(forTileArtifact: file), !ids.isEmpty {
            return ids
        }
        logger("Warning: no coverage derivable for \(file); publishing with no regions")
        return []
    }

    /// "San_Antonio_sectional.mbtiles" → "San Antonio Sectional" (mirrors the
    /// app's ChartStore display naming).
    private func displayName(_ file: String) -> String {
        file.replacingOccurrences(of: ".mbtiles", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
            .replacingOccurrences(of: "Ifr", with: "IFR")
    }

    // MARK: Sidecars

    private func expirationDate(for fileURL: URL) -> Date? {
        let sidecar = fileURL.appendingPathExtension("expires")
        guard let text = try? String(contentsOf: sidecar, encoding: .utf8) else { return nil }
        return ISO8601DateFormatter().date(from: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func cachedSHA256(of fileURL: URL, sizeBytes: Int64, attributes: [FileAttributeKey: Any]) throws -> String {
        let mtime = Int((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        let sidecar = fileURL.appendingPathExtension("sha256")

        if let cached = try? String(contentsOf: sidecar, encoding: .utf8) {
            let parts = cached.split(separator: " ")
            if parts.count == 3, Int64(parts[1]) == sizeBytes, Int(parts[2]) == mtime {
                return String(parts[0])
            }
        }

        logger("Hashing \(fileURL.lastPathComponent) (\(sizeBytes) bytes)…")
        let hash = try streamingSHA256(of: fileURL)
        try? "\(hash) \(sizeBytes) \(mtime)".write(to: sidecar, atomically: true, encoding: .utf8)
        return hash
    }

    private func streamingSHA256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
