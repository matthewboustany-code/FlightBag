import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import FBModels

/// Converts FAA raster charts (Lambert Conformal GeoTIFF) into Web-Mercator
/// MBTiles the app renders offline:
///
///   1. download the chart zip from aeronav.faa.gov (see `Source`)
///   2. `gdal_translate -expand rgba` (charts ship as 256-color palette)
///   3. `gdalwarp -t_srs EPSG:3857`
///   4. `gdal_translate -of MBTILES -co TILE_FORMAT=PNG8` + `gdaladdo` overviews
///
/// Chart collars are left visible in v0; cutline shapefiles strip them later.
/// GDAL runs as an external process (Docker image in production, any local
/// install during development via --gdal-bin).
struct TilePipeline {
    /// Which FAA chart product to ingest. Output filenames follow the
    /// `_sectional` / `_ifr_low` / `_ifr_high` suffix convention that both
    /// the app's ChartKind classifier and the manifest builder key off.
    enum Source {
        /// VFR sectional by FAA name, e.g. "San_Antonio".
        /// `aeronav.faa.gov/visual/{MM-dd-yyyy}/sectional-files/{chart}.zip`
        case sectional(chart: String)
        /// IFR enroute low panel 1...36.
        /// `aeronav.faa.gov/enroute/{MM-dd-yyyy}/enr_l{NN}.zip` (one
        /// ENR_L{NN}.tif per zip; verified 2026-07 against 07-09-2026).
        case enrouteLow(panel: Int)
        /// IFR enroute high panel 1...12, `enr_h{NN}.zip`.
        case enrouteHigh(panel: Int)
        /// Natural Earth II shaded-relief raster (public domain) — the
        /// offline basemap under the charts. Not an FAA product; the cycle
        /// only decides which artifact directory it publishes into.
        case naturalEarthBasemap

        var artifactFileName: String {
            switch self {
            case .sectional(let chart): return "\(chart)_sectional.mbtiles"
            case .enrouteLow(let panel): return String(format: "ENR_L%02d_ifr_low.mbtiles", panel)
            case .enrouteHigh(let panel): return String(format: "ENR_H%02d_ifr_high.mbtiles", panel)
            case .naturalEarthBasemap: return "basemap_natural_earth.mbtiles"
            }
        }

        /// Cache-file stem for the downloaded zip.
        var cacheStem: String {
            switch self {
            case .sectional(let chart): return chart
            case .enrouteLow(let panel): return String(format: "enr_l%02d", panel)
            case .enrouteHigh(let panel): return String(format: "enr_h%02d", panel)
            case .naturalEarthBasemap: return "NE2_HR_LC_SR_W"
            }
        }

        /// FAA chart editions run on a 56-day cadence — VFR sectionals just as
        /// much as IFR enroute panels. On roughly half of the 28-day AIRAC
        /// cycles there is no new edition and the current one carries over, so
        /// anything dated must be able to fall back to the prior cycle and must
        /// advertise an expiry beyond its own cycle. Treating sectionals as
        /// 28-day makes them 404 on every off cycle (2608 is one: there is a
        /// 07-09-2026 edition and a 09-03-2026 one, but no 08-06-2026).
        ///
        /// The basemap is Natural Earth, not an FAA product, and has no edition.
        var isFiftySixDayEdition: Bool {
            switch self {
            case .sectional, .enrouteLow, .enrouteHigh: return true
            case .naturalEarthBasemap: return false
            }
        }

        /// FAA charts ship as 256-color palettes needing `-expand rgba`;
        /// Natural Earth is already RGB (the expand step would fail on it).
        var needsPaletteExpansion: Bool {
            switch self {
            case .sectional, .enrouteLow, .enrouteHigh: return true
            case .naturalEarthBasemap: return false
            }
        }

        func remoteURL(for cycle: DataCycle) -> URL {
            let date = Self.dateComponent(for: cycle)
            switch self {
            case .sectional(let chart):
                return URL(string: "https://aeronav.faa.gov/visual/\(date)/sectional-files/\(chart).zip")!
            case .enrouteLow, .enrouteHigh:
                return URL(string: "https://aeronav.faa.gov/enroute/\(date)/\(cacheStem).zip")!
            case .naturalEarthBasemap:
                return URL(string: "https://naciscdn.org/naturalearth/10m/raster/NE2_HR_LC_SR_W.zip")!
            }
        }

        /// FAA chart directories are keyed by effective date, e.g. "07-09-2026".
        static func dateComponent(for cycle: DataCycle) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "MM-dd-yyyy"
            return formatter.string(from: cycle.effectiveDate)
        }
    }

    let workDirectory: URL
    /// Directory containing gdal_translate/gdalwarp/gdaladdo; nil = use PATH.
    let gdalBinDirectory: String?
    let logger: (String) -> Void

    /// The cycle whose chart directory actually contains this source.
    /// Dated editions only exist every other cycle, so a request during an
    /// off cycle walks back one cycle. Throws if neither exists.
    func resolveEditionCycle(for source: Source, requested: DataCycle) async throws -> DataCycle {
        guard source.isFiftySixDayEdition else { return requested }
        for candidate in [requested, requested.previous()] {
            if try await remoteExists(source.remoteURL(for: candidate)) {
                return candidate
            }
        }
        throw IngestError("No edition found for \(source.cacheStem) at \(Source.dateComponent(for: requested)) or the prior cycle")
    }

    func run(source: Source, cycle: DataCycle, output: String) async throws {
        let chartDir = workDirectory.appendingPathComponent("charts", isDirectory: true)
        try FileManager.default.createDirectory(at: chartDir, withIntermediateDirectories: true)

        // 1. Download & extract.
        let zipURL = chartDir.appendingPathComponent("\(source.cacheStem)_\(cycle.id).zip")
        if !FileManager.default.fileExists(atPath: zipURL.path) {
            let remote = source.remoteURL(for: cycle)
            logger("Downloading \(remote.absoluteString)…")
            var request = URLRequest(url: remote)
            request.setValue("Mozilla/5.0 (Macintosh) FlightBag-Ingest/1.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw IngestError("Chart download failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            }
            try data.write(to: zipURL)
        } else {
            logger("Using cached \(zipURL.lastPathComponent)")
        }

        let extractDir = chartDir.appendingPathComponent("\(source.cacheStem)_\(cycle.id)", isDirectory: true)
        try? FileManager.default.removeItem(at: extractDir)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        try runIngestProcess("/usr/bin/unzip", ["-o", "-q", zipURL.path, "-d", extractDir.path])

        guard let tif = try FileManager.default.contentsOfDirectory(atPath: extractDir.path)
            .first(where: { $0.lowercased().hasSuffix(".tif") }) else {
            throw IngestError("No GeoTIFF found in \(zipURL.lastPathComponent)")
        }
        let tifPath = extractDir.appendingPathComponent(tif).path

        // 2–4. GDAL conversion chain.
        let rgba = extractDir.appendingPathComponent("rgba.tif").path
        let mercator = extractDir.appendingPathComponent("mercator.tif").path
        let warpInput: String
        if source.needsPaletteExpansion {
            logger("Expanding palette to RGBA…")
            try gdal("gdal_translate", ["-q", "-expand", "rgba", tifPath, rgba])
            warpInput = rgba
        } else {
            warpInput = tifPath
        }
        logger("Reprojecting to EPSG:3857…")
        try gdal("gdalwarp", ["-q", "-t_srs", "EPSG:3857", "-r", "bilinear", "-dstalpha", "-co", "TILED=YES", warpInput, mercator])
        logger("Writing MBTiles…")
        try? FileManager.default.removeItem(atPath: output)
        try gdal("gdal_translate", ["-q", "-of", "MBTILES", "-co", "TILE_FORMAT=PNG8", mercator, output])
        logger("Building overview pyramid…")
        try gdal("gdaladdo", ["-q", "-r", "average", output, "2", "4", "8", "16", "32", "64"])

        // Intermediates are multi-GB; clean up.
        try? FileManager.default.removeItem(atPath: rgba)
        try? FileManager.default.removeItem(atPath: mercator)

        // 56-day editions outlive their cycle; the sidecar tells the manifest
        // builder how long to carry the artifact forward. Sectionals need this
        // as much as enroute panels — without it a sectional whose edition sits
        // under the prior cycle drops out of the next cycle's manifest.
        if source.isFiftySixDayEdition {
            let expires = cycle.next().next().effectiveDate
            let sidecar = output + ".expires"
            try ISO8601DateFormatter().string(from: expires).write(toFile: sidecar, atomically: true, encoding: .utf8)
            logger("Edition expires \(ISO8601DateFormatter().string(from: expires)) → \(sidecar)")
        }
        logger("MBTiles written to \(output)")
    }

    /// HEAD-probe for an artifact's existence; also used by `ingest-all` to
    /// detect whether the FAA has published the next cycle's charts yet.
    func remoteExists(_ url: URL) async throws -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue("Mozilla/5.0 (Macintosh) FlightBag-Ingest/1.0", forHTTPHeaderField: "User-Agent")
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private func gdal(_ tool: String, _ arguments: [String]) throws {
        let executable = gdalBinDirectory.map { "\($0)/\(tool)" } ?? tool
        try runIngestProcess(executable, arguments, searchPath: gdalBinDirectory == nil)
    }

    /// Tools the chart pipeline shells out to, in the order it uses them.
    static let requiredGDALTools = ["gdal_translate", "gdalwarp", "gdaladdo"]

    /// Check GDAL is present and usable before any chart work starts.
    ///
    /// Without this the first sign of a missing or broken `gdal-bin` is a
    /// process-spawn failure partway through `buildChart`, i.e. after a
    /// multi-hundred-megabyte download has already been paid for. Failing in
    /// the first second with the package name in the message is worth the one
    /// extra exec per tool.
    ///
    /// Only called when there is chart work to do — a database-only ingest
    /// must not require GDAL to be installed at all.
    @discardableResult
    func preflightGDAL() throws -> String {
        var version = "unknown"
        for tool in ["gdalinfo"] + Self.requiredGDALTools {
            let executable = gdalBinDirectory.map { "\($0)/\(tool)" } ?? tool
            do {
                let output = try capturingIngestProcess(
                    executable, ["--version"], searchPath: gdalBinDirectory == nil
                )
                if tool == "gdalinfo" {
                    version = output.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } catch {
                throw IngestError("""
                    GDAL tool "\(tool)" is not usable\(gdalBinDirectory.map { " in \($0)" } ?? " on PATH").
                    Chart ingestion needs gdal_translate, gdalwarp and gdaladdo.
                    In the container these come from the `gdal-bin` package; \
                    locally pass --gdal-bin, or set FLIGHTBAG_SECTIONALS/\
                    IFR panels to none to build the database only.
                    Underlying error: \(error)
                    """)
            }
        }
        return version
    }
}

/// Shared external-process helper for ingest pipelines (GDAL, unzip, zip).
/// Like `runIngestProcess`, but returns stdout — used for version probes.
@discardableResult
func capturingIngestProcess(_ executable: String, _ arguments: [String], searchPath: Bool = false) throws -> String {
    let process = Process()
    if searchPath {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
    } else {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
    }
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    // Read before waiting: a tool that outran the pipe buffer would deadlock.
    let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let errorOutput = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw IngestError("\(executable) failed (\(process.terminationStatus)): \(errorOutput.prefix(300))")
    }
    return output
}

func runIngestProcess(_ executable: String, _ arguments: [String], searchPath: Bool = false, currentDirectory: URL? = nil) throws {
    let process = Process()
    if searchPath {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
    } else {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
    }
    if let currentDirectory {
        process.currentDirectoryURL = currentDirectory
    }
    let stderr = Pipe()
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        throw IngestError("\(executable) failed (\(process.terminationStatus)): \(message.prefix(300))")
    }
}
