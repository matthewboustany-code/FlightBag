import Foundation
import FBModels

/// Converts FAA VFR raster charts (Lambert Conformal GeoTIFF) into
/// Web-Mercator MBTiles the app renders offline:
///
///   1. download `aeronav.faa.gov/visual/{MM-DD-YYYY}/sectional-files/{chart}.zip`
///   2. `gdal_translate -expand rgba` (charts ship as 256-color palette)
///   3. `gdalwarp -t_srs EPSG:3857`
///   4. `gdal_translate -of MBTILES -co TILE_FORMAT=PNG8` + `gdaladdo` overviews
///
/// Chart collars are left visible in v0; cutline shapefiles strip them later.
/// GDAL runs as an external process (Docker image in production, any local
/// install during development via --gdal-bin).
struct TilePipeline {
    let workDirectory: URL
    /// Directory containing gdal_translate/gdalwarp/gdaladdo; nil = use PATH.
    let gdalBinDirectory: String?
    let logger: (String) -> Void

    func run(chart: String, cycle: DataCycle, output: String) async throws {
        let chartDir = workDirectory.appendingPathComponent("charts", isDirectory: true)
        try FileManager.default.createDirectory(at: chartDir, withIntermediateDirectories: true)

        // 1. Download & extract.
        let zipURL = chartDir.appendingPathComponent("\(chart)_\(cycle.id).zip")
        if !FileManager.default.fileExists(atPath: zipURL.path) {
            let remote = URL(string: "https://aeronav.faa.gov/visual/\(visualDateComponent(for: cycle))/sectional-files/\(chart).zip")!
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

        let extractDir = chartDir.appendingPathComponent("\(chart)_\(cycle.id)", isDirectory: true)
        try? FileManager.default.removeItem(at: extractDir)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        try runProcess("/usr/bin/unzip", ["-o", "-q", zipURL.path, "-d", extractDir.path])

        guard let tif = try FileManager.default.contentsOfDirectory(atPath: extractDir.path)
            .first(where: { $0.lowercased().hasSuffix(".tif") }) else {
            throw IngestError("No GeoTIFF found in \(chart).zip")
        }
        let tifPath = extractDir.appendingPathComponent(tif).path

        // 2–4. GDAL conversion chain.
        let rgba = extractDir.appendingPathComponent("rgba.tif").path
        let mercator = extractDir.appendingPathComponent("mercator.tif").path
        logger("Expanding palette to RGBA…")
        try gdal("gdal_translate", ["-q", "-expand", "rgba", tifPath, rgba])
        logger("Reprojecting to EPSG:3857…")
        try gdal("gdalwarp", ["-q", "-t_srs", "EPSG:3857", "-r", "bilinear", "-dstalpha", "-co", "TILED=YES", rgba, mercator])
        logger("Writing MBTiles…")
        try? FileManager.default.removeItem(atPath: output)
        try gdal("gdal_translate", ["-q", "-of", "MBTILES", "-co", "TILE_FORMAT=PNG8", mercator, output])
        logger("Building overview pyramid…")
        try gdal("gdaladdo", ["-q", "-r", "average", output, "2", "4", "8", "16", "32", "64"])

        // Intermediates are multi-GB; clean up.
        try? FileManager.default.removeItem(atPath: rgba)
        try? FileManager.default.removeItem(atPath: mercator)
        logger("MBTiles written to \(output)")
    }

    /// VFR chart directories are keyed by effective date, e.g. "07-09-2026".
    private func visualDateComponent(for cycle: DataCycle) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "MM-dd-yyyy"
        return formatter.string(from: cycle.effectiveDate)
    }

    private func gdal(_ tool: String, _ arguments: [String]) throws {
        let executable = gdalBinDirectory.map { "\($0)/\(tool)" } ?? tool
        try runProcess(executable, arguments, searchPath: gdalBinDirectory == nil)
    }

    private func runProcess(_ executable: String, _ arguments: [String], searchPath: Bool = false) throws {
        let process = Process()
        if searchPath {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        } else {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
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
}
