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
    private let pacer: NMSRequestPacer

    /// - Parameter minimumRequestInterval: Seconds between outbound calls, the
    ///   token exchange included. Defaults just over Apigee's one-per-second
    ///   spike arrest; a self-hoster granted a higher rate can lower it.
    public init(
        credentials: NMSCredentials,
        environment: NMSEnvironment = .production,
        http: any HTTPGetting = URLSessionHTTPClient(),
        minimumRequestInterval: TimeInterval = 1.1
    ) {
        let pacer = NMSRequestPacer(minimumInterval: minimumRequestInterval)
        self.http = http
        self.environment = environment
        self.pacer = pacer
        self.tokens = NMSTokenStore(
            credentials: credentials,
            environment: environment,
            http: http,
            pacer: pacer
        )
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
        let data = try await nmsPaced(pacer) {
            try await http.get(components.url!, headers: [
                "Authorization": "Bearer \(token)",
                "Accept": "application/json",
                // NMS takes the response format as a header, not a query item.
                "nmsResponseFormat": "GEOJSON",
            ])
        }

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

// MARK: - Rate limiting

/// Holds outbound NMS calls to one per interval.
///
/// Apigee fronts NMS with a spike arrest — one request per second, burst one —
/// that the onboarding pack documents nowhere. It surfaces only as a 429 whose
/// body names `policies.ratelimit.SpikeArrestViolation`. That collides with the
/// briefing path, which fetches airports four at a time: without pacing, a cold
/// four-airport route loses three of them to 429 and the app reports them as
/// unavailable, at exactly the moment a pilot first asks.
///
/// An actor so concurrent callers queue instead of racing. Each reserves the
/// next slot *before* sleeping, so a burst becomes a train rather than four
/// callers all waking to the same instant.
actor NMSRequestPacer {
    private let minimumInterval: TimeInterval
    private var nextSlot: Date = .distantPast

    init(minimumInterval: TimeInterval) {
        self.minimumInterval = minimumInterval
    }

    /// Claims the next slot and sleeps until it opens. Reserving before the
    /// suspension is what serialises: a caller arriving mid-sleep takes the
    /// slot *after* the one being waited on, never the same one.
    func waitForSlot(now: Date = Date()) async throws {
        guard minimumInterval > 0 else { return }
        let slot = max(now, nextSlot)
        nextSlot = slot.addingTimeInterval(minimumInterval)

        let delay = slot.timeIntervalSince(now)
        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    /// Pushes the whole queue back after a rejection. Without this the callers
    /// already holding slots march straight into the same wall.
    func penalise(now: Date = Date()) {
        nextSlot = max(nextSlot, now).addingTimeInterval(minimumInterval)
    }
}

/// Runs one outbound NMS call in a paced slot, retrying once if the spike
/// arrest rejects it anyway — a neighbouring client's traffic, or clock skew,
/// can spend the window we thought was ours.
///
/// One retry only. A briefing that reports a gap beats a briefing that hangs:
/// the caller above turns a throw into a 502, and the app falls back to its own
/// cached NOTAMs rather than drawing the conclusion that an airport has none.
func nmsPaced<T>(_ pacer: NMSRequestPacer, _ operation: () async throws -> T) async throws -> T {
    try await pacer.waitForSlot()
    do {
        return try await operation()
    } catch let error as HTTPError where error.statusCode == 429 {
        await pacer.penalise()
        try await pacer.waitForSlot()
        return try await operation()
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
    private let pacer: NMSRequestPacer
    private var token: String?
    private var expiresAt: Date = .distantPast
    private var refresh: Task<String, Error>?

    init(
        credentials: NMSCredentials,
        environment: NMSEnvironment,
        http: any HTTPGetting,
        pacer: NMSRequestPacer
    ) {
        self.credentials = credentials
        self.environment = environment
        self.http = http
        self.pacer = pacer
    }

    func bearerToken(now: Date = Date()) async throws -> String {
        if let token, now < expiresAt { return token }

        // Actors are reentrant, so the caller below releases this actor the
        // moment it suspends on the exchange. Without joining an in-flight
        // one, four concurrent briefing fetches each find the cache empty and
        // start their own — four tokens spending four slots of a
        // one-per-second budget, three of them thrown away.
        if let refresh { return try await refresh.value }

        let task = Task { try await self.exchange(now: now) }
        refresh = task
        defer { refresh = nil }
        return try await task.value
    }

    private func exchange(now: Date) async throws -> String {
        let pair = "\(credentials.clientId):\(credentials.clientSecret)"
        guard let basic = pair.data(using: .utf8)?.base64EncodedString() else {
            throw NMSError.tokenRequestFailed("credentials are not UTF-8")
        }
        let body = Data("grant_type=client_credentials".utf8)
        // Bound to locals first: capturing `self` would make the closure
        // actor-isolated, and it has to run off the actor so a caller waiting
        // for its slot doesn't hold the token store hostage.
        let http = self.http
        let authURL = environment.authURL

        // The token exchange is spike-arrested like everything else, so it
        // shares the same budget rather than being a free extra request.
        let data = try await nmsPaced(pacer) {
            try await http.post(authURL, body: body, headers: [
                "Content-Type": "application/x-www-form-urlencoded",
                "Authorization": "Basic \(basic)",
                "Accept": "application/json",
            ])
        }

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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decode(String.self, forKey: .accessToken)

        // NMS fronts its OAuth endpoint with Apigee, which publishes every
        // numeric field in the token response as a **quoted string**
        // ("expires_in": "1799"). Decoding that straight into a TimeInterval
        // throws, and since this is the first call of every request cycle it
        // would take the whole NOTAM feature down with it. Accept either form.
        //
        // A missing expiry degrades to "expired now": the next call exchanges
        // a fresh token rather than the provider failing outright.
        if let seconds = try? container.decodeIfPresent(TimeInterval.self, forKey: .expiresIn) {
            expiresIn = seconds
        } else {
            expiresIn = (try? container.decode(String.self, forKey: .expiresIn)).flatMap(TimeInterval.init) ?? 0
        }
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
        guard let text = notam.bestText(translations: properties?.translations ?? []),
              !text.isEmpty
        else { return nil }

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

/// A GeoJSON geometry, which NMS publishes as a `GeometryCollection` pairing
/// the NOTAM's centre Point with the polygon outline of the same area.
///
/// Two things this has to survive. A polygon's `coordinates` is `[[[Double]]]`,
/// not `[Double]`, so typing that field concretely fails the *entire* response
/// on any NOTAM with an outline — the opposite of the tolerance the rest of
/// this file promises. And the centre is nested one level down inside
/// `geometries`, not at the top.
struct NMSGeometry: Decodable {
    let type: String?
    let point: Coordinate?
    let geometries: [NMSGeometry]?

    enum CodingKeys: String, CodingKey {
        case type, coordinates, geometries
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        geometries = (try? container.decodeIfPresent([NMSGeometry].self, forKey: .geometries)) ?? nil

        // Only a Point carries a usable centre. Anything else nests its
        // coordinates more deeply and is dropped, not mis-read as a point.
        let pair = (try? container.decodeIfPresent([Double].self, forKey: .coordinates)) ?? nil
        if type == "Point", let pair, pair.count >= 2 {
            // GeoJSON is [longitude, latitude].
            point = Coordinate(latitude: pair[1], longitude: pair[0])
        } else {
            point = nil
        }
    }

    /// The published centre: this geometry if it is a Point, otherwise the
    /// first Point inside a GeometryCollection — which is the centre the
    /// NOTAM's radius is measured from.
    var coordinate: Coordinate? {
        if let point { return point }
        return geometries?.lazy.compactMap(\.coordinate).first
    }
}

/// The GeoJSON feature body. NMS inherits FNS's `coreNOTAMData` nesting, but
/// the FAA's own client leaves it untyped, so a flat form is accepted too and
/// whichever arrives wins.
struct NMSProperties: Decodable {
    let coreNOTAMData: NMSCoreNOTAMData?
    private let flat: NMSNotam?

    var notam: NMSNotam? { coreNOTAMData?.notam ?? flat }
    var translations: [NMSNotamTranslation] { coreNOTAMData?.notamTranslation ?? [] }

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
    let notamTranslation: [NMSNotamTranslation]?
}

/// The formatted renderings of a NOTAM. NMS has no plain-language field —
/// these are the full domestic and ICAO messages, number and location
/// included, which is why they serve only as a fallback for `text`.
struct NMSNotamTranslation: Decodable {
    let type: String?
    let domesticMessage: String?
    let icaoMessage: String?

    var anyMessage: String? { domesticMessage ?? icaoMessage }

    enum CodingKeys: String, CodingKey {
        case type
        case domesticMessage = "domestic_message"
        case icaoMessage = "icao_message"
    }
}

/// A value NMS quotes even when it is a number or a boolean (`"radius": "5"`,
/// `"estimated": "true"`). The FAA's own client leaves the feature body
/// untyped, so nothing guarantees the quoting stays put; decoding either form
/// keeps one unquoted field from failing the whole response.
struct NMSScalar: Decodable {
    let text: String

    var doubleValue: Double? { Double(text) }

    var boolValue: Bool? {
        switch text.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true", "1": true
        case "false", "0": false
        default: nil
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            text = string
        } else if let bool = try? container.decode(Bool.self) {
            text = bool ? "true" : "false"
        } else if let int = try? container.decode(Int.self) {
            text = String(int)
        } else {
            text = String(try container.decode(Double.self))
        }
    }
}

struct NMSNotam: Decodable {
    let id: String?
    let number: String?
    let location: String?
    let icaoLocation: String?
    let classification: String?
    let selectionCode: String?
    let text: String?
    let effectiveStart: String?
    let effectiveEnd: String?
    let estimated: NMSScalar?
    let radius: NMSScalar?
    // Lower-case "l" — this is the spelling NMS publishes, and `minimumFL`
    // silently decodes as nil against it, taking every altitude limit with it.
    let minimumFl: NMSScalar?
    let maximumFl: NMSScalar?
    /// One ICAO-format string, not a decimal latitude/longitude pair.
    let coordinates: NMSScalar?

    /// The NOTAM body. `text` is the condition alone ("TWY A CLSD"), which is
    /// what a briefing wants next to the number and location it already shows.
    /// A translation is only a fallback, since each one repeats those.
    func bestText(translations: [NMSNotamTranslation]) -> String? {
        let body = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let body, !body.isEmpty { return body }

        let fallback = translations.first { $0.type == "LOCAL_FORMAT" }?.domesticMessage
            ?? translations.lazy.compactMap(\.anyMessage).first
        let trimmed = fallback?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    /// NMS states this outright, so the published flag wins: a NOTAM can carry
    /// `estimated: "true"` *and* a perfectly parseable end date, and reading
    /// only the date presents an estimate as a hard stop — the dangerous
    /// direction to be wrong in. The end value is read only when the flag is
    /// absent, where "PERM" and "EST" still mean the stop time is soft.
    var endIsEstimated: Bool {
        if let estimated, let flag = estimated.boolValue { return flag }
        guard let effectiveEnd else { return true }
        let upper = effectiveEnd.uppercased()
        return upper.contains("PERM") || upper.contains("EST") || Self.date(effectiveEnd) == nil
    }

    var effectiveStartDate: Date? { effectiveStart.flatMap(Self.date) }
    var effectiveEndDate: Date? { effectiveEnd.flatMap(Self.date) }

    /// Nautical miles, published bare ("5") or zero-padded ("005"). Zero means
    /// "not stated", not "a zero-mile circle", so it maps to nil.
    var radiusNM: Double? {
        guard let value = radius?.doubleValue, value > 0 else { return nil }
        return value
    }

    /// Flight levels, i.e. hundreds of feet.
    var lowerLimitFt: Int? { Self.flightLevelFeet(minimumFl?.text) }
    var upperLimitFt: Int? { Self.flightLevelFeet(maximumFl?.text) }

    var coordinate: Coordinate? {
        coordinates.flatMap { Self.coordinate(fromICAOString: $0.text) }
    }

    /// NMS publishes the centre the way the Q-line does — "3939N04302E", i.e.
    /// DDMM[SS] latitude then DDDMM[SS] longitude, each with a hemisphere
    /// letter. Neither decimal degrees nor two separate fields.
    static func coordinate(fromICAOString value: String) -> Coordinate? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let latEnd = text.firstIndex(where: { $0 == "N" || $0 == "S" }) else { return nil }
        let afterLat = text.index(after: latEnd)
        guard let lonEnd = text[afterLat...].firstIndex(where: { $0 == "E" || $0 == "W" }) else { return nil }

        guard var latitude = sexagesimal(String(text[text.startIndex..<latEnd]), degreeDigits: 2),
              var longitude = sexagesimal(String(text[afterLat..<lonEnd]), degreeDigits: 3),
              latitude <= 90, longitude <= 180
        else { return nil }

        if text[latEnd] == "S" { latitude = -latitude }
        if text[lonEnd] == "W" { longitude = -longitude }
        return Coordinate(latitude: latitude, longitude: longitude)
    }

    /// DDMM / DDMMSS, and the three-digit-degree longitude forms. Everything
    /// is zero-padded, so the split is positional.
    private static func sexagesimal(_ digits: String, degreeDigits: Int) -> Double? {
        let chars = Array(digits)
        guard chars.allSatisfy(\.isNumber), chars.count >= degreeDigits + 2 else { return nil }
        guard let degrees = Double(String(chars[0..<degreeDigits])),
              let minutes = Double(String(chars[degreeDigits..<(degreeDigits + 2)])),
              minutes < 60
        else { return nil }

        var value = degrees + minutes / 60
        if chars.count >= degreeDigits + 4 {
            guard let seconds = Double(String(chars[(degreeDigits + 2)..<(degreeDigits + 4)])),
                  seconds < 60
            else { return nil }
            value += seconds / 3_600
        }
        return value
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
