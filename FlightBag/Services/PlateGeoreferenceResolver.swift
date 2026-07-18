import Foundation
import CoreGraphics
import CoreLocation
import FBModels

/// The one place that answers "can this plate be pinned to the map, and
/// where?". IAPs use their embedded georeferencing; airport diagrams fall
/// back to runway matching against NASR (AirportDiagramGeoreference), with
/// results — including failures — cached so the PDF scan runs once per
/// chart per cycle.
enum PlateGeoreferenceResolver {
    static func resolve(plate: PlateMetadata, url: URL, database: AeroDatabase?) async -> PlateGeoreference? {
        // Embedded georef first: covers IAPs, and any chart type the FAA
        // starts georeferencing in a future cycle.
        if let embedded = await parseDetached(url: url) {
            return embedded
        }
        guard plate.category == .airportDiagram, let database else { return nil }

        let key = cacheKey(for: plate)
        if let cached = Cache.shared.lookup(key) {
            return cached.georeference
        }
        guard let detail = try? await database.airportDetail(id: plate.airportId) else { return nil }
        let runways = detail.airport.runways
        let matched = await Task.detached(priority: .userInitiated) {
            AirportDiagramGeoreference.match(url: url, runways: runways)
        }.value
        Cache.shared.store(key, georeference: matched, cycle: plate.cycle)
        return matched
    }

    private static func parseDetached(url: URL) async -> PlateGeoreference? {
        await Task.detached(priority: .userInitiated) {
            PlateGeoreference.parse(url: url)
        }.value
    }

    private static func cacheKey(for plate: PlateMetadata) -> String {
        "\(AirportDiagramGeoreference.matcherVersion)|\(plate.pdfName)|\(plate.cycle)"
    }

    // MARK: Cache

    /// Tiny JSON cache (ManifestClient idiom). Stores negative results too,
    /// so unmatchable diagrams don't re-run the scanner on every open.
    final class Cache: @unchecked Sendable {
        static let shared = Cache()

        struct Entry: Codable {
            var cycle: String
            var pageIndex: Int?
            var bbox: [Double]?
            /// lat/lon interleaved, TL,TR,BR,BL; nil = cached failure.
            var corners: [Double]?

            var georeference: PlateGeoreference? {
                guard let pageIndex, let bbox, bbox.count == 4,
                      let corners, corners.count == 8 else { return nil }
                return PlateGeoreference(
                    pageIndex: pageIndex,
                    pdfBBox: CGRect(x: bbox[0], y: bbox[1], width: bbox[2], height: bbox[3]),
                    corners: stride(from: 0, to: 8, by: 2).map {
                        CLLocationCoordinate2D(latitude: corners[$0], longitude: corners[$0 + 1])
                    }
                )
            }
        }

        private let queue = DispatchQueue(label: "Me.FlightBag.georef-cache")
        private var entries: [String: Entry]
        private let fileURL: URL = {
            let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            return support.appendingPathComponent("FlightBag/plates/georef-cache.json")
        }()

        private init() {
            entries = (try? JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: fileURL))) ?? [:]
        }

        func lookup(_ key: String) -> Entry? {
            queue.sync { entries[key] }
        }

        func store(_ key: String, georeference: PlateGeoreference?, cycle: String) {
            queue.sync {
                entries[key] = Entry(
                    cycle: cycle,
                    pageIndex: georeference?.pageIndex,
                    bbox: georeference.map { [$0.pdfBBox.origin.x, $0.pdfBBox.origin.y, $0.pdfBBox.width, $0.pdfBBox.height] },
                    corners: georeference.map { $0.corners.flatMap { [$0.latitude, $0.longitude] } }
                )
                // Old cycles' charts are gone; keep the file tiny. Two
                // cycles coexist during rollover, so keep the neighbor too.
                let kept: Set<String> = [
                    cycle,
                    DataCycle(id: cycle)?.previous().id,
                    DataCycle(id: cycle)?.next().id,
                ].compactMap { $0 }.reduce(into: []) { $0.insert($1) }
                entries = entries.filter { kept.contains($0.value.cycle) }
                try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let data = try? JSONEncoder().encode(entries) {
                    try? data.write(to: fileURL, options: .atomic)
                }
            }
        }
    }
}
