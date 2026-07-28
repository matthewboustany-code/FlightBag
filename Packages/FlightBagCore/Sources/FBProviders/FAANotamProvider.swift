import Foundation
import FBModels

/// NOTAMs from the FAA NOTAM Management Service (NMS).
///
/// NMS replaced the US NOTAM System on 2026-04-18; the older
/// `external-api.faa.gov/notamapi/v1` (FNS) endpoint is on its way out, so
/// this targets NMS from the start. Two things follow from that choice:
///
/// - Auth is OAuth 2.0 `client_credentials`, not a static key, so there is a
///   token to fetch, cache and refresh (`NMSTokenStore`).
/// - Credentials come from the FAA by request (NOTAMS@faa.gov) and must never
///   ship in the app binary. This provider is therefore constructed
///   **server-side only**; the app reaches NOTAMs through the FlightBag
///   server's `/v1/airports/:id/notams` proxy.
public struct FAANotamProvider: NotamProvider {
    let http: any HTTPGetting
    let environment: NMSEnvironment
    private let tokens: NMSTokenStore

    public init(
        credentials: NMSCredentials,
        environment: NMSEnvironment = .production,
        http: any HTTPGetting = URLSessionHTTPClient()
    ) {
        self.http = http
        self.environment = environment
        self.tokens = NMSTokenStore(credentials: credentials, environment: environment, http: http)
    }

    public func notams(for location: ICAOIdentifier) async throws -> [Notam] {
        try await fetch(query: [URLQueryItem(name: "location", value: location.rawValue)], fallbackLocation: location)
    }

    /// Area search, for the route briefing and map layers. `radiusNM` is
    /// passed through as NMS's `radius`.
    public func notams(near coordinate: Coordinate, radiusNM: Int) async throws -> [Notam] {
        try await fetch(query: [
            URLQueryItem(name: "latitude", value: String(coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(coordinate.longitude)),
            URLQueryItem(name: "radius", value: String(radiusNM)),
        ], fallbackLocation: nil)
    }

    private func fetch(query: [URLQueryItem], fallbackLocation: ICAOIdentifier?) async throws -> [Notam] {
        var components = URLComponents(
            url: environment.apiBaseURL.appendingPathComponent("v1/notams"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = query

        let token = try await tokens.bearerToken()
        let data = try await http.get(components.url!, headers: [
            "Authorization": "Bearer \(token)",
            "Accept": "application/json",
            // NMS takes the response format as a header, not a query item.
            "nmsResponseFormat": "GEOJSON",
        ])

        // Dates stay strings through decoding: NOTAM end times are
        // legitimately non-dates ("PERM", "EST"), and a decoding strategy
        // would fail the whole response over one of them. `NMSNotam` parses
        // them itself and keeps the un-parseable ones as "estimated".
        let response = try JSONDecoder().decode(NMSNotamResponse.self, from: data)
        if let error = response.errors?.first {
            throw NMSError.service(code: error.code, message: error.message)
        }
        return (response.data?.geojson ?? []).compactMap { $0.toNotam(fallbackLocation: fallbackLocation) }
    }
}

// MARK: - Configuration

public struct NMSCredentials: Sendable, Hashable {
    public var clientId: String
    public var clientSecret: String

    public init(clientId: String, clientSecret: String) {
        self.clientId = clientId
        self.clientSecret = clientSecret
    }
}

/// NMS publishes staging and FIT environments alongside production; a
/// self-hoster testing an integration should be able to point at FIT without
/// touching code.
public enum NMSEnvironment: String, Sendable, CaseIterable {
    case production
    case staging
    case fit

    public var authURL: URL {
        switch self {
        case .production: URL(string: "https://api-nms.aim.faa.gov/v1/auth/token")!
        case .staging: URL(string: "https://api-staging.cgifederal-aim.com/v1/auth/token")!
        case .fit: URL(string: "https://api-fit.cgifederal-aim.com/v1/auth/token")!
        }
    }

    public var apiBaseURL: URL {
        switch self {
        case .production: URL(string: "https://api-nms.aim.faa.gov/nmsapi")!
        case .staging: URL(string: "https://api-staging.cgifederal-aim.com/nmsapi")!
        case .fit: URL(string: "https://api-fit.cgifederal-aim.com/nmsapi")!
        }
    }
}

public enum NMSError: Error, CustomStringConvertible {
    case tokenRequestFailed(String)
    case service(code: String?, message: String?)

    public var description: String {
        switch self {
        case .tokenRequestFailed(let detail):
            "NMS token request failed: \(detail)"
        case .service(let code, let message):
            "NMS error \(code ?? "—"): \(message ?? "no detail")"
        }
    }
}

// MARK: - Token management

/// Caches the NMS bearer token and refreshes it lazily.
///
/// An actor because the server shares one provider across concurrent
/// requests, and a burst of them must produce one token exchange, not one
/// per request. Refresh runs 60 s early so a token can't expire mid-flight
/// between the check and the call that uses it.
actor NMSTokenStore {
    private let credentials: NMSCredentials
    private let environment: NMSEnvironment
    private let http: any HTTPGetting
    private var token: String?
    private var expiresAt: Date = .distantPast

    init(credentials: NMSCredentials, environment: NMSEnvironment, http: any HTTPGetting) {
        self.credentials = credentials
        self.environment = environment
        self.http = http
    }

    func bearerToken(now: Date = Date()) async throws -> String {
        if let token, now < expiresAt { return token }

        let pair = "\(credentials.clientId):\(credentials.clientSecret)"
        guard let basic = pair.data(using: .utf8)?.base64EncodedString() else {
            throw NMSError.tokenRequestFailed("credentials are not UTF-8")
        }
        let body = Data("grant_type=client_credentials".utf8)
        let data = try await http.post(environment.authURL, body: body, headers: [
            "Content-Type": "application/x-www-form-urlencoded",
            "Authorization": "Basic \(basic)",
            "Accept": "application/json",
        ])

        let response: NMSTokenResponse
        do {
            response = try JSONDecoder().decode(NMSTokenResponse.self, from: data)
        } catch {
            throw NMSError.tokenRequestFailed("unreadable token response")
        }
        token = response.accessToken
        expiresAt = now.addingTimeInterval(max(response.expiresIn - 60, 0))
        return response.accessToken
    }
}

struct NMSTokenResponse: Decodable {
    let accessToken: String
    let expiresIn: TimeInterval

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
    }
}

// MARK: - Wire format

// NMS wraps its payload in a status/data envelope and returns NOTAMs as
// GeoJSON features. The FAA's own published client types the feature body as
// an untyped map, so every field below is optional and a feature that doesn't
// yield an id and text is dropped rather than failing the whole response —
// the same tolerance `DataAuthority` applies to unknown authorities.

struct NMSNotamResponse: Decodable {
    let status: String?
    let errors: [NMSServiceError]?
    let data: NMSNotamData?
}

struct NMSServiceError: Decodable {
    let code: String?
    let message: String?
}

struct NMSNotamData: Decodable {
    let geojson: [NMSFeature]?
}

struct NMSFeature: Decodable {
    let geometry: NMSGeometry?
    let properties: NMSProperties?

    func toNotam(fallbackLocation: ICAOIdentifier?) -> Notam? {
        guard let notam = properties?.notam else { return nil }
        guard let text = notam.bestText, !text.isEmpty else { return nil }

        let locationValue = notam.icaoLocation ?? notam.location ?? fallbackLocation?.rawValue
        guard let locationValue, !locationValue.isEmpty else { return nil }
        // Prefer the human NOTAM number ("01/005") over the 16-digit internal
        // id: it's what a pilot reads back and what FIS-B uplinks carry.
        guard let id = notam.number ?? notam.id else { return nil }

        return Notam(
            id: id,
            location: ICAOIdentifier(locationValue),
            text: text,
            classification: notam.classification,
            effectiveStart: notam.effectiveStartDate,
            effectiveEnd: notam.effectiveEndDate,
            endIsEstimated: notam.endIsEstimated,
            qCode: notam.selectionCode,
            coordinate: geometry?.coordinate ?? notam.coordinate,
            radiusNM: notam.radiusNM,
            lowerLimitFt: notam.lowerLimitFt,
            upperLimitFt: notam.upperLimitFt
        )
    }
}

struct NMSGeometry: Decodable {
    let type: String?
    let coordinates: [Double]?

    /// Only points carry a usable centre here; polygons decode as nested
    /// arrays and are ignored rather than mis-read as a point.
    var coordinate: Coordinate? {
        guard type == "Point", let coordinates, coordinates.count >= 2 else { return nil }
        // GeoJSON is [longitude, latitude].
        return Coordinate(latitude: coordinates[1], longitude: coordinates[0])
    }
}

/// The GeoJSON feature body. NMS inherits FNS's `coreNOTAMData` nesting, but
/// the FAA's own client leaves it untyped, so a flat form is accepted too and
/// whichever arrives wins.
struct NMSProperties: Decodable {
    let coreNOTAMData: NMSCoreNOTAMData?
    private let flat: NMSNotam?

    var notam: NMSNotam? { coreNOTAMData?.notam ?? flat }

    enum CodingKeys: String, CodingKey {
        case coreNOTAMData
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        coreNOTAMData = try container.decodeIfPresent(NMSCoreNOTAMData.self, forKey: .coreNOTAMData)
        flat = coreNOTAMData == nil ? try? NMSNotam(from: decoder) : nil
    }
}

struct NMSCoreNOTAMData: Decodable {
    let notam: NMSNotam?
}

struct NMSNotam: Decodable {
    let id: String?
    let number: String?
    let location: String?
    let icaoLocation: String?
    let classification: String?
    let selectionCode: String?
    let text: String?
    let translatedText: String?
    let effectiveStart: String?
    let effectiveEnd: String?
    let radius: String?
    let minimumFL: String?
    let maximumFL: String?
    let latitude: String?
    let longitude: String?

    enum CodingKeys: String, CodingKey {
        case id, number, location, icaoLocation, classification, selectionCode
        case text, translatedText, effectiveStart, effectiveEnd, radius
        case minimumFL, maximumFL, latitude, longitude
    }

    var bestText: String? {
        let candidate = translatedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let candidate, !candidate.isEmpty { return candidate }
        return text?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "PERM" and "EST" are valid end values and mean the end time is not a
    /// hard stop — the reason `Notam.endIsEstimated` exists.
    var endIsEstimated: Bool {
        guard let effectiveEnd else { return true }
        let upper = effectiveEnd.uppercased()
        return upper.contains("PERM") || upper.contains("EST") || Self.date(effectiveEnd) == nil
    }

    var effectiveStartDate: Date? { effectiveStart.flatMap(Self.date) }
    var effectiveEndDate: Date? { effectiveEnd.flatMap(Self.date) }

    /// Published as a 3-digit NM string ("005"). Zero means "not stated",
    /// not "a zero-mile circle", so it maps to nil.
    var radiusNM: Double? {
        guard let radius, let value = Double(radius), value > 0 else { return nil }
        return value
    }

    /// Flight levels, i.e. hundreds of feet.
    var lowerLimitFt: Int? { Self.flightLevelFeet(minimumFL) }
    var upperLimitFt: Int? { Self.flightLevelFeet(maximumFL) }

    var coordinate: Coordinate? {
        guard let latitude, let longitude,
              let lat = Double(latitude), let lon = Double(longitude) else { return nil }
        return Coordinate(latitude: lat, longitude: lon)
    }

    private static func flightLevelFeet(_ value: String?) -> Int? {
        guard let value, let level = Int(value) else { return nil }
        return level * 100
    }

    private static func date(_ string: String) -> Date? {
        if let date = try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return date
        }
        return try? Date(string, strategy: .iso8601)
    }
}
