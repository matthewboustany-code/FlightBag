import Foundation
import FBModels

/// Discovers downloaded chart tile sets:
/// `Application Support/FlightBag/cycles/{cycle}/tiles/*.mbtiles`.
/// Also imports any .mbtiles dropped in Documents (Files-app sideload) into
/// the current cycle, until CDN-backed region downloads arrive.
struct ChartStore: Sendable {
    struct ChartSet: Identifiable, Sendable, Hashable {
        var id: String { url.path }
        var name: String
        var cycleId: String
        var url: URL
        var kind: ChartKind
        /// Who published it, from the `.authority` sidecar written at install.
        /// nil for sideloaded sets, whose provenance we genuinely do not know.
        var authority: DataAuthority?
    }

    private let cyclesRoot: URL
    private let documentsRoot: URL?

    init() {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        cyclesRoot = support.appendingPathComponent("FlightBag/cycles")
        documentsRoot = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    }

    func availableCharts() -> [ChartSet] {
        importSideloadedCharts()
        return scanTileSets { !$0.hasPrefix("basemap") }
    }

    /// Downloaded offline basemaps (`basemap_*.mbtiles`) — rendered under the
    /// aeronautical charts, never listed as one.
    func availableBasemaps() -> [ChartSet] {
        scanTileSets { $0.hasPrefix("basemap") }
    }

    /// What kind of chart a tile set is.
    ///
    /// Prefers the `.kind` sidecar `DownloadCenter` writes from the manifest's
    /// `contentKind`, which is the authority. Falls back to inferring from the
    /// filename for sideloaded charts and for sets installed before the
    /// sidecar existed — that inference is substring-based and only reliable
    /// for FAA naming, which is exactly why the manifest value wins.
    static func kind(for url: URL, fileName: String) -> ChartKind {
        if let data = try? Data(contentsOf: url.appendingPathExtension("kind")),
           let raw = String(data: data, encoding: .utf8),
           let contentKind = DownloadProduct.ContentKind(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           let kind = ChartKind(contentKind: contentKind) {
            return kind
        }
        return ChartKind.kind(forFileName: fileName)
    }

    /// Who published a tile set, from the sidecar `DownloadCenter` writes.
    ///
    /// Deliberately nil rather than `.faa` when absent: a sideloaded chart has
    /// unknown provenance, and defaulting it to the FAA would print a credit
    /// that might be wrong while hiding one that is required.
    static func authority(for url: URL) -> DataAuthority? {
        guard let data = try? Data(contentsOf: url.appendingPathExtension("authority")),
              let raw = String(data: data, encoding: .utf8)
        else { return nil }
        let authority = DataAuthority(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        return authority == .unknown ? nil : authority
    }

    private func scanTileSets(matching include: (String) -> Bool) -> [ChartSet] {
        let fileManager = FileManager.default
        guard let cycles = try? fileManager.contentsOfDirectory(atPath: cyclesRoot.path) else { return [] }
        var sets: [ChartSet] = []
        for cycle in cycles.sorted().reversed() {
            let tilesDir = cyclesRoot.appendingPathComponent("\(cycle)/tiles")
            guard let files = try? fileManager.contentsOfDirectory(atPath: tilesDir.path) else { continue }
            for file in files where file.hasSuffix(".mbtiles") && include(file) {
                // Keep only the newest cycle's copy of a given chart name.
                let name = displayName(for: file)
                guard !sets.contains(where: { $0.name == name }) else { continue }
                let url = tilesDir.appendingPathComponent(file)
                sets.append(ChartSet(
                    name: name,
                    cycleId: cycle,
                    url: url,
                    kind: Self.kind(for: url, fileName: file),
                    authority: Self.authority(for: url)
                ))
            }
        }
        return sets.sorted { $0.name < $1.name }
    }

    /// Total chart-tile bytes across all cycles (Downloads tab display).
    nonisolated func storedByteCount() -> Int64 {
        guard let cycles = try? FileManager.default.contentsOfDirectory(atPath: cyclesRoot.path) else { return 0 }
        var total: Int64 = 0
        for cycle in cycles {
            let tilesDir = cyclesRoot.appendingPathComponent("\(cycle)/tiles")
            guard let enumerator = FileManager.default.enumerator(at: tilesDir, includingPropertiesForKeys: [.fileSizeKey]) else {
                continue
            }
            for case let url as URL in enumerator {
                total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
        }
        return total
    }

    /// "San_Antonio_sectional.mbtiles" → "San Antonio Sectional"
    private func displayName(for file: String) -> String {
        file.replacingOccurrences(of: ".mbtiles", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    private func importSideloadedCharts() {
        let fileManager = FileManager.default
        guard let documentsRoot,
              let files = try? fileManager.contentsOfDirectory(atPath: documentsRoot.path) else { return }
        let targetDir = cyclesRoot.appendingPathComponent("\(DataCycle.current().id)/tiles")
        for file in files where file.hasSuffix(".mbtiles") {
            try? fileManager.createDirectory(at: targetDir, withIntermediateDirectories: true)
            let source = documentsRoot.appendingPathComponent(file)
            let target = targetDir.appendingPathComponent(file)
            try? fileManager.removeItem(at: target)
            try? fileManager.moveItem(at: source, to: target)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableTarget = target
            try? mutableTarget.setResourceValues(values)
        }
    }
}
