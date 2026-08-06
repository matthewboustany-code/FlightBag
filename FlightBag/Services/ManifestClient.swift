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
    ///
    /// `failure` explains why the network path did not produce a manifest, so
    /// the UI can say which of "wrong scheme", "wrong host", "server up but
    /// answering 500", and "genuinely offline" happened. Collapsing all of
    /// those into one "unreachable" makes a five-second fix take an afternoon.
    /// It is non-nil even when a cached manifest is returned, so a caller can
    /// show stale data and still report that the refresh failed.
    func fetch() async -> (manifest: DownloadManifest?, failure: String?) {
        guard let baseURL = ServerConfig.baseURL else { return (cached(), nil) }
        do {
            var request = URLRequest(url: baseURL.appendingPathComponent("v1/manifest"))
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return (cached(), "The server gave a non-HTTP response.")
            }
            guard http.statusCode == 200 else {
                return (cached(), "The server answered HTTP \(http.statusCode) for /v1/manifest.")
            }
            do {
                let manifest = try Self.decoder().decode(DownloadManifest.self, from: data)
                try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: cacheURL, options: .atomic)
                return (manifest, nil)
            } catch {
                // A manifest we cannot read is a version mismatch, not an outage.
                return (cached(), "The server sent a manifest this version of the app cannot read.")
            }
        } catch {
            return (cached(), Self.describe(error, baseURL: baseURL))
        }
    }

    /// Turns a URLError into something that names the actual fix.
    private static func describe(_ error: Error, baseURL: URL) -> String {
        let host = baseURL.host() ?? baseURL.absoluteString
        guard let urlError = error as? URLError else { return error.localizedDescription }
        switch urlError.code {
        case .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid:
            // Far and away the most common cause on a LAN: https:// typed at a
            // server that only speaks plain HTTP, which is how FlightBag's own
            // deployment runs until a domain and a reverse proxy exist.
            if baseURL.scheme == "https" {
                return "Could not establish a secure connection to \(host). A LAN server usually serves plain HTTP — try http:// instead of https://."
            }
            return "Could not establish a secure connection to \(host)."
        case .appTransportSecurityRequiresSecureConnection:
            return "iOS blocked the connection to \(host) because it is not encrypted."
        case .badURL, .unsupportedURL:
            return "\"\(baseURL.absoluteString)\" is not a usable address — include the scheme, e.g. http://192.168.1.50:8080."
        case .cannotConnectToHost:
            return "Nothing answered at \(host). Check the server is running and that this device is on the same network."
        case .cannotFindHost:
            return "Could not find \(host)."
        case .timedOut:
            return "Timed out reaching \(host)."
        case .notConnectedToInternet, .networkConnectionLost:
            return "No network connection."
        default:
            return urlError.localizedDescription
        }
    }

    func cached() -> DownloadManifest? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? Self.decoder().decode(DownloadManifest.self, from: data)
    }
}
