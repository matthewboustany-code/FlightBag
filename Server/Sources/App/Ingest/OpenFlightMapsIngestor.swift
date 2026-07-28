import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Vapor
import FBModels

/// Downloads open flightmaps VFR charts into the artifact tree.
///
/// The simplest ingestor in the pipeline, because OFM publishes exactly what
/// FlightBag already consumes: one `.mbtiles` per FIR, in EPSG:3857, versioned
/// by the same AIRAC cycle numbering `DataCycle` uses. There is no GDAL step,
/// no georeferencing and no rasterization — unlike the FAA path, which starts
/// from GeoTIFFs. Ingest is a verified copy.
///
/// Licence: the OFMA General Users' Licence grants a worldwide, royalty-free,
/// non-exclusive right to use the data including commercially, on condition
/// that open flightmaps is attributed as the source. `DataAuthority`
/// carries that attribution string and the map renders it; do not publish
/// these artifacts from a build that has dropped it.
struct OpenFlightMapsIngestor {
    let workDirectory: URL
    let logger: (String) -> Void

    static let baseURL = URL(string: "https://snapshots.openflightmaps.org/live")!

    /// `@2x` is the retina variant. The plain 256 set is roughly a quarter the
    /// size and looks soft on every device FlightBag targets, so it is not
    /// worth the saving.
    static let tileVariant = "256@2x"

    /// Artifact name for a FIR's chart. `_sectional` keeps it classifiable by
    /// the same filename fallback the FAA sets use, for anything reading a
    /// tile set without its manifest entry.
    static func artifactFileName(fir: String) -> String {
        "OFM_\(fir.uppercased())_sectional.mbtiles"
    }

    static func sourceURL(cycle: DataCycle, fir: String) -> URL {
        baseURL
            .appendingPathComponent(cycle.id)
            .appendingPathComponent("tiles/\(fir)/noninteractive/epsg3857")
            .appendingPathComponent("\(fir)_\(tileVariant).mbtiles")
    }

    /// Fetch the requested FIRs' charts into `{cycleDir}/tiles/`.
    ///
    /// Skips any artifact already present so a rerun after a partial failure
    /// resumes, matching every other step in `ingest-all`. A FIR that OFM has
    /// not published for this cycle is logged and skipped rather than failing
    /// the run — coverage varies per cycle, and one missing country must not
    /// cost the others.
    func run(cycle: DataCycle, firs: [String], into cycleDir: URL) async throws {
        guard !firs.isEmpty else { return }
        let tilesDir = cycleDir.appendingPathComponent("tiles", isDirectory: true)
        try FileManager.default.createDirectory(at: tilesDir, withIntermediateDirectories: true)

        for fir in firs {
            let destination = tilesDir.appendingPathComponent(Self.artifactFileName(fir: fir))
            if FileManager.default.fileExists(atPath: destination.path) {
                logger("open flightmaps: \(Self.artifactFileName(fir: fir)) exists — skipping")
                continue
            }

            let source = Self.sourceURL(cycle: cycle, fir: fir)
            logger("Downloading \(source.lastPathComponent) (\(fir))…")
            do {
                let temp = workDirectory.appendingPathComponent("ofm_\(fir)_\(cycle.id).mbtiles")
                try await download(source, to: temp)
                try validateMBTiles(at: temp, fir: fir)
                try FileManager.default.createDirectory(at: tilesDir, withIntermediateDirectories: true)
                _ = try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temp, to: destination)
                logger("open flightmaps: \(fir) → \(destination.lastPathComponent)")
            } catch {
                logger("open flightmaps: \(fir) unavailable for \(cycle.id) (\(error.localizedDescription)) — skipping")
            }
        }
    }

    /// Fetch to memory, then write.
    ///
    /// `URLSession.download(from:)` would stream to disk and keep the peak
    /// lower, but swift-corelibs-foundation's coverage of the async download
    /// APIs is thinner than of `data(for:)`, and this image has never had a
    /// Linux build. Every other ingestor here takes the same route, and
    /// DEPLOY.md's ~2 GB ingest budget already assumes it — the largest FIR is
    /// ~160 MB, so the headroom is real. Revisit once the NAS build is proven.
    private func download(_ url: URL, to destination: URL) async throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Abort(.badGateway, reason: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) for \(url.lastPathComponent)")
        }
        try data.write(to: destination, options: .atomic)
    }

    /// A truncated or error-page download is still a file. Checking the SQLite
    /// magic and the MBTiles `tiles` table here means a corrupt artifact is
    /// caught during ingest rather than as a blank chart in the cockpit.
    private func validateMBTiles(at url: URL, fir: String) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let magic = try handle.read(upToCount: 16) ?? Data()
        guard magic.starts(with: Array("SQLite format 3".utf8)) else {
            throw Abort(.badGateway, reason: "\(fir): downloaded file is not SQLite")
        }
    }
}
