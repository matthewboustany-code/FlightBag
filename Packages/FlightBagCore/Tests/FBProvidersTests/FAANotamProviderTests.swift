import Foundation
import Testing
import FBModels
@testable import FBProviders

/// Serves a canned token response to the POST and a canned payload to the
/// GET, and records what it was asked for — the auth handshake is half of
/// what's worth testing here.
final class NMSStubHTTPClient: HTTPGetting, @unchecked Sendable {
    let payload: Data
    let tokenPayload: Data
    private(set) var getURLs: [URL] = []
    private(set) var getHeaders: [[String: String]] = []
    private(set) var postCount = 0
    private(set) var postHeaders: [[String: String]] = []
    private(set) var postBodies: [String] = []

    init(payload: Data, expiresIn: Int = 3600, accessToken: String = "tok-abc") {
        self.payload = payload
        self.tokenPayload = Data(#"{"access_token":"\#(accessToken)","expires_in":\#(expiresIn)}"#.utf8)
    }

    func get(_ url: URL) async throws -> Data {
        try await get(url, headers: [:])
    }

    func get(_ url: URL, headers: [String: String]) async throws -> Data {
        getURLs.append(url)
        getHeaders.append(headers)
        return payload
    }

    func post(_ url: URL, body: Data, headers: [String: String]) async throws -> Data {
        postCount += 1
        postHeaders.append(headers)
        postBodies.append(String(decoding: body, as: UTF8.self))
        return tokenPayload
    }
}

@Suite struct FAANotamProviderTests {
    private func fixture(_ name: String) throws -> Data {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json")
            ?? Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
        return try Data(contentsOf: #require(url))
    }

    private func provider(_ http: NMSStubHTTPClient) -> FAANotamProvider {
        FAANotamProvider(
            credentials: NMSCredentials(clientId: "id", clientSecret: "secret"),
            http: http
        )
    }

    @Test func decodesNotamsFromTheGeoJSONEnvelope() async throws {
        let http = NMSStubHTTPClient(payload: try fixture("nms_notams_kaus"))
        let notams = try await provider(http).notams(for: ICAOIdentifier("KAUS"))

        // The third feature has empty text and is dropped, not surfaced blank.
        #expect(notams.count == 2)

        let taxiway = try #require(notams.first)
        #expect(taxiway.id == "01/005")
        #expect(taxiway.location.rawValue == "KAUS")
        #expect(taxiway.text == "TWY A CLSD")
        #expect(taxiway.qCode == "QMXLC")
        #expect(taxiway.classification == "DOMESTIC")
        #expect(taxiway.radiusNM == 5)
        #expect(taxiway.lowerLimitFt == 0)
        #expect(taxiway.upperLimitFt == 99_900)
        #expect(taxiway.endIsEstimated == false)

        let centre = try #require(taxiway.coordinate)
        // GeoJSON orders [lon, lat]; getting this backwards puts Austin in Antarctica.
        #expect(abs(centre.latitude - 30.1945278) < 0.000_01)
        #expect(abs(centre.longitude - (-97.6698889)) < 0.000_01)
    }

    @Test func prefersTranslatedTextOverRawWhenPresent() async throws {
        let http = NMSStubHTTPClient(payload: try fixture("nms_notams_kaus"))
        let notams = try await provider(http).notams(for: ICAOIdentifier("KAUS"))
        let obstruction = try #require(notams.first { $0.id == "01/006" })
        #expect(obstruction.text.hasPrefix("Obstruction: crane erected"))
    }

    @Test func treatsPermanentEndAsEstimatedAndStillActive() async throws {
        let http = NMSStubHTTPClient(payload: try fixture("nms_notams_kaus"))
        let notams = try await provider(http).notams(for: ICAOIdentifier("KAUS"))
        let obstruction = try #require(notams.first { $0.id == "01/006" })

        #expect(obstruction.endIsEstimated)
        #expect(obstruction.effectiveEnd == nil)
        // A PERM NOTAM must never age out of a briefing.
        #expect(obstruction.isActive(at: Date(timeIntervalSince1970: 4_000_000_000)))
    }

    @Test func dropsZeroRadiusRatherThanDrawingAZeroMileCircle() async throws {
        let http = NMSStubHTTPClient(payload: try fixture("nms_notams_kaus"))
        let notams = try await provider(http).notams(for: ICAOIdentifier("KAUS"))
        let obstruction = try #require(notams.first { $0.id == "01/006" })
        // No geometry in the feature, but the notam body carries a radius —
        // without a centre there is nothing to draw.
        #expect(obstruction.coordinate == nil)
        #expect(obstruction.mapCircle == nil)
    }

    @Test func sendsBearerTokenAndGeoJSONFormatHeader() async throws {
        let http = NMSStubHTTPClient(payload: try fixture("nms_notams_kaus"))
        _ = try await provider(http).notams(for: ICAOIdentifier("KAUS"))

        let headers = try #require(http.getHeaders.first)
        #expect(headers["Authorization"] == "Bearer tok-abc")
        #expect(headers["nmsResponseFormat"] == "GEOJSON")

        let url = try #require(http.getURLs.first)
        #expect(url.absoluteString.contains("api-nms.aim.faa.gov/nmsapi/v1/notams"))
        #expect(url.query?.contains("location=KAUS") == true)
    }

    @Test func exchangesCredentialsWithBasicAuthClientCredentialsGrant() async throws {
        let http = NMSStubHTTPClient(payload: try fixture("nms_notams_kaus"))
        _ = try await provider(http).notams(for: ICAOIdentifier("KAUS"))

        #expect(http.postCount == 1)
        let headers = try #require(http.postHeaders.first)
        // base64("id:secret")
        #expect(headers["Authorization"] == "Basic aWQ6c2VjcmV0")
        #expect(headers["Content-Type"] == "application/x-www-form-urlencoded")
        #expect(http.postBodies.first == "grant_type=client_credentials")
    }

    @Test func reusesTheTokenAcrossRequests() async throws {
        let http = NMSStubHTTPClient(payload: try fixture("nms_notams_kaus"))
        let provider = provider(http)
        _ = try await provider.notams(for: ICAOIdentifier("KAUS"))
        _ = try await provider.notams(for: ICAOIdentifier("KDAL"))
        _ = try await provider.notams(for: ICAOIdentifier("KHOU"))

        // Three fetches, one token exchange.
        #expect(http.postCount == 1)
        #expect(http.getURLs.count == 3)
    }

    @Test func refetchesTheTokenOnceItExpires() async throws {
        let http = NMSStubHTTPClient(payload: try fixture("nms_notams_kaus"), expiresIn: 30)
        let store = NMSTokenStore(
            credentials: NMSCredentials(clientId: "id", clientSecret: "secret"),
            environment: .production,
            http: http
        )
        let now = Date()
        _ = try await store.bearerToken(now: now)
        // expires_in 30 with the 60 s refresh margin means already expired.
        _ = try await store.bearerToken(now: now)
        #expect(http.postCount == 2)
    }

    @Test func surfacesServiceErrors() async throws {
        let payload = Data(#"{"status":"ERROR","errors":[{"code":"400","message":"Bad Request"}]}"#.utf8)
        let http = NMSStubHTTPClient(payload: payload)
        await #expect(throws: NMSError.self) {
            _ = try await provider(http).notams(for: ICAOIdentifier("KAUS"))
        }
    }

    @Test func emptyResponseIsEmptyNotAnError() async throws {
        let http = NMSStubHTTPClient(payload: Data(#"{"status":"SUCCESS","data":{"geojson":[]}}"#.utf8))
        let notams = try await provider(http).notams(for: ICAOIdentifier("KAUS"))
        #expect(notams.isEmpty)
    }

    @Test func acceptsAFlatFeatureBodyWithoutCoreNOTAMDataNesting() async throws {
        // The FAA's own client types the feature body as an untyped map, so
        // the nesting is not guaranteed; a flat body must still decode.
        let payload = Data("""
        {"status":"SUCCESS","data":{"geojson":[{"type":"Feature","geometry":null,
        "properties":{"number":"02/010","icaoLocation":"KAUS","text":"RWY 18L/36R CLSD",
        "classification":"DOMESTIC","effectiveStart":"2026-07-20T12:00:00.000Z",
        "effectiveEnd":"2026-07-21T12:00:00.000Z"}}]}}
        """.utf8)
        let http = NMSStubHTTPClient(payload: payload)
        let notams = try await provider(http).notams(for: ICAOIdentifier("KAUS"))

        let notam = try #require(notams.first)
        #expect(notam.id == "02/010")
        #expect(notam.text == "RWY 18L/36R CLSD")
        #expect(notam.endIsEstimated == false)
    }

    @Test func fallsBackToTheQueriedLocationWhenTheFeatureOmitsOne() async throws {
        let payload = Data("""
        {"status":"SUCCESS","data":{"geojson":[{"type":"Feature","geometry":null,
        "properties":{"number":"03/001","text":"AD CLSD"}}]}}
        """.utf8)
        let http = NMSStubHTTPClient(payload: payload)
        let notams = try await provider(http).notams(for: ICAOIdentifier("KAUS"))
        #expect(notams.first?.location.rawValue == "KAUS")
    }

    @Test func areaSearchPassesLatLonRadius() async throws {
        let http = NMSStubHTTPClient(payload: try fixture("nms_notams_kaus"))
        _ = try await provider(http).notams(
            near: Coordinate(latitude: 30.19, longitude: -97.67),
            radiusNM: 50
        )
        let query = try #require(http.getURLs.first?.query)
        #expect(query.contains("latitude=30.19"))
        #expect(query.contains("longitude=-97.67"))
        #expect(query.contains("radius=50"))
    }

    @Test func fitEnvironmentPointsAtTheTestHost() {
        #expect(NMSEnvironment.fit.apiBaseURL.host() == "api-fit.cgifederal-aim.com")
        #expect(NMSEnvironment.production.authURL.absoluteString == "https://api-nms.aim.faa.gov/v1/auth/token")
    }
}

@Suite struct NotamModelTests {
    @Test func activeWindowRespectsStartAndEnd() {
        let start = Date(timeIntervalSince1970: 1_000)
        let end = Date(timeIntervalSince1970: 2_000)
        let notam = Notam(
            id: "01/001",
            location: ICAOIdentifier("KAUS"),
            text: "TWY A CLSD",
            effectiveStart: start,
            effectiveEnd: end
        )
        #expect(!notam.isActive(at: Date(timeIntervalSince1970: 999)))
        #expect(notam.isActive(at: Date(timeIntervalSince1970: 1_500)))
        #expect(!notam.isActive(at: Date(timeIntervalSince1970: 2_001)))
    }

    @Test func missingTimesReadAsInForce() {
        let notam = Notam(id: "01/002", location: ICAOIdentifier("KAUS"), text: "AD CLSD")
        // The safe failure: a notice with no stated validity is shown, not hidden.
        #expect(notam.isActive(at: Date(timeIntervalSince1970: 0)))
        #expect(notam.isActive(at: Date(timeIntervalSince1970: 4_000_000_000)))
    }

    @Test func mapCircleNeedsBothCentreAndRadius() {
        let centre = Coordinate(latitude: 30.19, longitude: -97.67)
        #expect(Notam(id: "a", location: ICAOIdentifier("KAUS"), text: "x", coordinate: centre).mapCircle == nil)
        #expect(Notam(id: "b", location: ICAOIdentifier("KAUS"), text: "x", radiusNM: 5).mapCircle == nil)
        #expect(Notam(id: "c", location: ICAOIdentifier("KAUS"), text: "x", coordinate: centre, radiusNM: 5).mapCircle != nil)
    }
}
