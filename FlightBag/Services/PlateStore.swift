import Foundation
import FBModels

/// Downloads and stores approach plate PDFs per cycle:
/// `Application Support/FlightBag/cycles/{cycle}/plates/{airport}/{pdf}`.
/// Viewing a plate caches it automatically; "Download All" prefetches an
/// airport for offline use.
actor PlateStore {
    enum PlateError: Error {
        case noURL
        case downloadFailed(Int)
    }

    private let root: URL
    private var inFlight: [String: Task<URL, Error>] = [:]

    init() {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        root = support.appendingPathComponent("FlightBag/cycles")
    }

    private func localURL(for plate: PlateMetadata) -> URL {
        root.appendingPathComponent("\(plate.cycle)/plates/\(plate.airportId)/\(plate.pdfName)")
    }

    /// True when the plate is already stored locally.
    func isDownloaded(_ plate: PlateMetadata) -> Bool {
        FileManager.default.fileExists(atPath: localURL(for: plate).path)
    }

    func downloadedCount(for plates: [PlateMetadata]) -> Int {
        plates.filter { isDownloaded($0) }.count
    }

    /// Local file URL for the plate, downloading it first if needed.
    func fetch(_ plate: PlateMetadata) async throws -> URL {
        let local = localURL(for: plate)
        if FileManager.default.fileExists(atPath: local.path) {
            return local
        }
        if let existing = inFlight[plate.id] {
            return try await existing.value
        }
        guard let remote = plate.url else { throw PlateError.noURL }

        let task = Task<URL, Error> {
            var request = URLRequest(url: remote)
            request.setValue("FlightBag/1.0", forHTTPHeaderField: "User-Agent")
            let (tempURL, response) = try await URLSession.shared.download(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw PlateError.downloadFailed((response as? HTTPURLResponse)?.statusCode ?? -1)
            }
            try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: local)
            try FileManager.default.moveItem(at: tempURL, to: local)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableLocal = local
            try? mutableLocal.setResourceValues(values)
            return local
        }
        inFlight[plate.id] = task
        defer { inFlight[plate.id] = nil }
        return try await task.value
    }

    /// Prefetch every plate for an airport. Returns the number that failed.
    func downloadAll(_ plates: [PlateMetadata], progress: @Sendable @escaping (Int, Int) -> Void) async -> Int {
        var failures = 0
        for (index, plate) in plates.enumerated() {
            do {
                _ = try await fetch(plate)
            } catch {
                failures += 1
            }
            progress(index + 1, plates.count)
        }
        return failures
    }

    /// Total plate bytes across all cycles (Downloads tab display). Only the
    /// `plates/` subtrees count — chart tiles have their own tally in
    /// ChartStore.
    nonisolated func storedByteCount() -> Int64 {
        guard let cycles = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return 0 }
        var total: Int64 = 0
        for cycle in cycles {
            let platesDir = root.appendingPathComponent("\(cycle)/plates")
            guard let enumerator = FileManager.default.enumerator(at: platesDir, includingPropertiesForKeys: [.fileSizeKey]) else {
                continue
            }
            for case let url as URL in enumerator {
                total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
        }
        return total
    }
}
