import Foundation
import FBModels

/// Where the FlightBag backend lives. No default server ships yet — until a
/// deployment exists, the URL comes from Settings or the `-serverBaseURL`
/// launch argument (launch args surface through UserDefaults automatically,
/// which is how simulator verification points at a local Vapor server).
enum ServerConfig {
    static let defaultsKey = "serverBaseURL"

    static var baseURL: URL? {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              !raw.isEmpty else { return nil }
        return URL(string: raw)
    }
}

/// Fetches `/v1/manifest` and caches the raw JSON so the Downloads tab keeps
/// working offline (the whole point of the feature is being airborne without
/// internet).
struct ManifestClient: Sendable {
    private let cacheURL: URL

    init() {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        cacheURL = support.appendingPathComponent("FlightBag/downloads/manifest-cache.json")
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Fetch from the configured server, falling back to the cached copy.
    /// Returns nil when neither is available (no server configured and
    /// nothing cached).
    func fetch() async -> DownloadManifest? {
        if let baseURL = ServerConfig.baseURL {
            do {
                var request = URLRequest(url: baseURL.appendingPathComponent("v1/manifest"))
                request.timeoutInterval = 15
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 200,
                   let manifest = try? Self.decoder().decode(DownloadManifest.self, from: data) {
                    try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? data.write(to: cacheURL, options: .atomic)
                    return manifest
                }
            } catch {
                // Offline or unreachable — fall through to cache.
            }
        }
        return cached()
    }

    func cached() -> DownloadManifest? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? Self.decoder().decode(DownloadManifest.self, from: data)
    }
}
