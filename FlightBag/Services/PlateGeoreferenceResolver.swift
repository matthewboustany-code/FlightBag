import Foundation
import CoreGraphics
import CoreLocation
import FBModels

/// The one place that answers "can this plate be pinned to the map, and
/// where?". IAPs use their embedded georeferencing; airport diagrams fall
/// back to runway matching against NASR (AirportDiagramGeoreference);
/// military IAPs — DoD charts carry no embedded georef — fall back to
/// registering planview RNAV stars against surveyed fixes
/// (ApproachFixGeoreference). Results — including failures — are cached so
/// the PDF scan runs once per chart per cycle.
enum PlateGeoreferenceResolver {
    static func resolve(plate: PlateMetadata, url: URL, database: AeroDatabase?) async -> PlateGeoreference? {
        // Embedded georef first: covers civil IAPs, and any chart type the
        // FAA starts georeferencing in a future cycle.
        if let embedded = await parseDetached(url: url) {
            return embedded
        }
        guard let database else { return nil }

        switch plate.category {
        case .airportDiagram:
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

        case .approach:
            let key = cacheKey(for: plate)
            if let cached = Cache.shared.lookup(key) {
                return cached.georeference
            }
            guard let candidates = try? await fixCandidates(around: plate.airportId, database: database),
                  !candidates.isEmpty else { return nil }
            let matched = await Task.detached(priority: .userInitiated) {
                ApproachFixGeoreference.match(url: url, candidates: candidates)
            }.value
            Cache.shared.store(key, georeference: matched, cycle: plate.cycle)
            return matched

        default:
            // DPs and STARs are not drawn to scale; deliberately nil.
            return nil
        }
    }

    /// Everything a planview star could represent: fixes, navaids, and
    /// runway thresholds within the widest span a planview covers
    /// (TAA plates reach past their 30 NM rings).
    private static func fixCandidates(around airportId: String, database: AeroDatabase) async throws -> [ApproachFixGeoreference.Candidate] {
        guard let detail = try? await database.airportDetail(id: airportId) else { return [] }
        let latitude = detail.airport.coordinate.latitude
        let longitude = detail.airport.coordinate.longitude
        let latSpan = 0.9
        let lonSpan = latSpan / max(0.2, cos(latitude * .pi / 180))
        let fixes = try await database.fixesIn(
            minLat: latitude - latSpan, maxLat: latitude + latSpan,
            minLon: longitude - lonSpan, maxLon: longitude + lonSpan, limit: 2000
        )
        let navaids = try await database.navaidsIn(
            minLat: latitude - latSpan, maxLat: latitude + latSpan,
            minLon: longitude - lonSpan, maxLon: longitude + lonSpan, limit: 300
        )
        var candidates = (fixes + navaids).map {
            ApproachFixGeoreference.Candidate(identifier: $0.identifier, latitude: $0.latitude, longitude: $0.longitude)
        }
        for runway in detail.airport.runways {
            for end in runway.ends {
                guard let coordinate = end.coordinate else { continue }
                candidates.append(ApproachFixGeoreference.Candidate(
                    identifier: "RW\(end.designator)", latitude: coordinate.latitude, longitude: coordinate.longitude
                ))
            }
        }
        return candidates
    }

    private static func parseDetached(url: URL) async -> PlateGeoreference? {
        await Task.detached(priority: .userInitiated) {
            PlateGeoreference.parse(url: url)
        }.value
    }

    private static func cacheKey(for plate: PlateMetadata) -> String {
        "\(AirportDiagramGeoreference.matcherVersion).\(ApproachFixGeoreference.matcherVersion)|\(plate.pdfName)|\(plate.cycle)"
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
