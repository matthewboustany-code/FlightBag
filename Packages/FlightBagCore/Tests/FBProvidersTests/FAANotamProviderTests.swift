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
    private let lock = NSLock()
    private var pendingGetFailures: [Int]
    private var _getURLs: [URL] = []
    private var _getHeaders: [[String: String]] = []
    private var _postCount = 0
    private var _postHeaders: [[String: String]] = []
    private var _postBodies: [String] = []

    var getURLs: [URL] { lock.withLock { _getURLs } }
    var getHeaders: [[String: String]] { lock.withLock { _getHeaders } }
    var postCount: Int { lock.withLock { _postCount } }
    var postHeaders: [[String: String]] { lock.withLock { _postHeaders } }
    var postBodies: [String] { lock.withLock { _postBodies } }

    /// NMS fronts its OAuth endpoint with Apigee, which quotes every numeric
    /// field in the token response. A stub that emits a bare number tests a
    /// response the live service never sends, so the quoted form is default.
    ///
    /// `getFailures` are thrown one per GET before the payload is served, for
    /// exercising the spike-arrest retry.
    init(
        payload: Data,
        expiresIn: Int = 3600,
        accessToken: String = "tok-abc",
        getFailures: [Int] = []
    ) {
        self.payload = payload
        self.pendingGetFailures = getFailures
        self.tokenPayload = Data(#"{"access_token":"\#(accessToken)","expires_in":"\#(expiresIn)"}"#.utf8)
    }

    init(payload: Data, tokenPayload: Data) {
        self.payload = payload
        self.pendingGetFailures = []
        self.tokenPayload = tokenPayload
    }

    func get(_ url: URL) async throws -> Data {
        try await get(url, headers: [:])
    }

    func get(_ url: URL, headers: [String: String]) async throws -> Data {
        let failure: Int? = lock.withLock {
            _getURLs.append(url)
            _getHeaders.append(headers)
            return pendingGetFailures.isEmpty ? nil : pendingGetFailures.removeFirst()
        }
        if let failure {
            throw HTTPError(statusCode: failure, url: url)
        }
        return payload
    }

    func post(_ url: URL, body: Data, headers: [String: String]) async throws -> Data {
        lock.withLock {
            _postCount += 1
            _postHeaders.append(headers)
            _postBodies.append(String(decoding: body, as: UTF8.self))
        }
        return tokenPayload
    }
}

@Suite struct FAANotamProviderTests {
    private func fixture(_ name: String) throws -> Data {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json")
            ?? Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
        return try Data(contentsOf: #require(url))
    }

    /// Pacing defaults to zero here so the decoding tests don't sit through
    /// Apigee's one-per-second budget; the pacing tests set it explicitly.
    private func provider(_ http: NMSStubHTTPClient, interval: TimeInterval = 0) -> FAANotamProvider {
        FAANotamProvider(
            credentials: NMSCredentials(clientId: "id", clientSecret: "secret"),
            http: http,
            minimumRequestInterval: interval
        )
    }

    private func notams(_ name: String = "nms_notams_kaus") async throws -> [Notam] {
        try await provider(NMSStubHTTPClient(payload: try fixture(name)))
            .notams(for: ICAOIdentifier("KAUS"))
    }

    @Test func decodesNotamsFromTheGeoJSONEnvelope() async throws {
        let notams = try await notams()

        // Five features in, one dropped: the fourth has whitespace-only text
        // and no translation to fall back on.
        #expect(notams.count == 4)

        let taxiway = try #require(notams.first)
        #expect(taxiway.id == "01/005")
        #expect(taxiway.location.rawValue == "KAUS")
        #expect(taxiway.text == "TWY A CLSD")
        #expect(taxiway.qCode == "QMXLC")
        #expect(taxiway.classification == "DOM")
        #expect(taxiway.radiusNM == 5)
        #expect(taxiway.lowerLimitFt == 0)
        #expect(taxiway.upperLimitFt == 99_900)
        #expect(taxiway.endIsEstimated == false)
    }

    @Test func readsTheCentreFromAGeometryCollectionBesideAPolygon() async throws {
        // NMS pairs the centre Point with the polygon outline of the same
        // NOTAM. Typing `coordinates` as [Double] fails the whole response on
        // the polygon; requiring type == "Point" at the top level misses the
        // centre entirely. Both together are why nothing used to plot.
        let taxiway = try #require(try await notams().first)
        let centre = try #require(taxiway.coordinate)
        // GeoJSON orders [lon, lat]; getting this backwards puts Austin in Antarctica.
        #expect(abs(centre.latitude - 30.1945278) < 0.000_01)
        #expect(abs(centre.longitude - (-97.6698889)) < 0.000_01)
    }

    @Test func parsesTheICAOCoordinateStringWhenTheFeatureHasNoGeometry() async throws {
        // The notam body publishes its centre as "3011N09740W", not as a
        // decimal latitude/longitude pair.
        let obstruction = try #require(try await notams().first { $0.id == "01/006" })
        let centre = try #require(obstruction.coordinate)
        #expect(abs(centre.latitude - 30.183_333) < 0.000_01)
        #expect(abs(centre.longitude - (-97.666_667)) < 0.000_01)
        #expect(obstruction.mapCircle != nil)
    }

    @Test func publishedEstimatedFlagBeatsAParseableEndTime() async throws {
        // 01/006 carries estimated: "true" *and* a valid ISO end date.
        // Reading only the date would present an estimate as a hard stop.
        let obstruction = try #require(try await notams().first { $0.id == "01/006" })
        #expect(obstruction.endIsEstimated)
        #expect(obstruction.effectiveEnd != nil)
        #expect(obstruction.isActive(at: Date(timeIntervalSince1970: 4_000_000_000)))
    }

    @Test func treatsPermanentEndAsEstimatedAndStillActive() async throws {
        let beacon = try #require(try await notams().first { $0.id == "01/007" })
        #expect(beacon.endIsEstimated)
        #expect(beacon.effectiveEnd == nil)
        // A PERM NOTAM must never age out of a briefing.
        #expect(beacon.isActive(at: Date(timeIntervalSince1970: 4_000_000_000)))
    }

    @Test func dropsZeroRadiusRatherThanDrawingAZeroMileCircle() async throws {
        let beacon = try #require(try await notams().first { $0.id == "01/007" })
        #expect(beacon.radiusNM == nil)
        #expect(beacon.mapCircle == nil)
    }

    @Test func fallsBackToTheDomesticMessageWhenTheBodyIsMissing() async throws {
        // NMS has no plain-language field: notamTranslation carries the fully
        // formatted domestic and ICAO messages. Better than dropping a NOTAM.
        let closure = try #require(try await notams().first { $0.id == "01/009" })
        #expect(closure.text == "!AUS 01/009 AUS RWY 18L/36R CLSD")
    }

    @Test func dropsFeaturesWithNoUsableText() async throws {
        #expect(try await notams().contains { $0.id == "01/008" } == false)
    }

    @Test func decodesTheFAAsPublishedSampleVerbatim() async throws {
        // The exact feature from the NMS-API 1.0.17 spec, byte for byte.
        let sample = try await notams("nms_notams_faa_sample")
        let notam = try #require(sample.first)

        #expect(notam.id == "01/123")
        #expect(notam.location.rawValue == "KCLT")
        #expect(notam.text == "27 RWY END ID LGT U/S")
        #expect(notam.classification == "DOM")
        #expect(notam.qCode == "QXXX")
        #expect(notam.radiusNM == 5)
        #expect(notam.lowerLimitFt == 0)
        #expect(notam.upperLimitFt == 99_900)
        #expect(notam.endIsEstimated)

        let centre = try #require(notam.coordinate)
        #expect(abs(centre.latitude - 40.0024157777778) < 0.000_01)
        #expect(abs(centre.longitude - (-81.1918244444444)) < 0.000_01)
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

    @Test func acceptsTheQuotedExpiresInApigeeActuallySends() async throws {
        // "expires_in": "1799" — quoted. Decoding it straight into a
        // TimeInterval throws, and this is the first call of every request
        // cycle, so the failure takes every NOTAM with it.
        let http = NMSStubHTTPClient(
            payload: try fixture("nms_notams_kaus"),
            tokenPayload: Data(#"{"access_token":"tok-quoted","expires_in":"1799"}"#.utf8)
        )
        _ = try await provider(http).notams(for: ICAOIdentifier("KAUS"))
        #expect(http.getHeaders.first?["Authorization"] == "Bearer tok-quoted")
    }

    @Test func acceptsABareNumericExpiresInToo() async throws {
        let http = NMSStubHTTPClient(
            payload: try fixture("nms_notams_kaus"),
            tokenPayload: Data(#"{"access_token":"tok-bare","expires_in":1799}"#.utf8)
        )
        _ = try await provider(http).notams(for: ICAOIdentifier("KAUS"))
        #expect(http.getHeaders.first?["Authorization"] == "Bearer tok-bare")
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
            http: http,
            pacer: NMSRequestPacer(minimumInterval: 0)
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
        let http = NMSStubHTTPClient(payload: Data(#"{"status":"Success","data":{"geojson":[]}}"#.utf8))
        let notams = try await provider(http).notams(for: ICAOIdentifier("KAUS"))
        #expect(notams.isEmpty)
    }

    @Test func acceptsAFlatFeatureBodyWithoutCoreNOTAMDataNesting() async throws {
        // The FAA's own client types the feature body as an untyped map, so
        // the nesting is not guaranteed; a flat body must still decode.
        let payload = Data("""
        {"status":"Success","data":{"geojson":[{"type":"Feature","geometry":null,
        "properties":{"number":"02/010","icaoLocation":"KAUS","text":"RWY 18L/36R CLSD",
        "classification":"DOM","effectiveStart":"2026-07-20T12:00:00.000Z",
        "effectiveEnd":"2026-07-21T12:00:00.000Z"}}]}}
        """.utf8)
        let http = NMSStubHTTPClient(payload: payload)
        let notams = try await provider(http).notams(for: ICAOIdentifier("KAUS"))

        let notam = try #require(notams.first)
        #expect(notam.id == "02/010")
        #expect(notam.text == "RWY 18L/36R CLSD")
        #expect(notam.endIsEstimated == false)
    }

    @Test func toleratesUnquotedScalarsInTheUntypedFeatureBody() async throws {
        // Nothing guarantees NMS keeps quoting its numbers and booleans, and
        // one unquoted field must not fail the whole response.
        let payload = Data("""
        {"status":"Success","data":{"geojson":[{"type":"Feature","geometry":null,
        "properties":{"number":"02/011","icaoLocation":"KAUS","text":"AD CLSD",
        "estimated":true,"radius":7,"minimumFl":0,"maximumFl":120}}]}}
        """.utf8)
        let http = NMSStubHTTPClient(payload: payload)
        let notam = try #require(try await provider(http).notams(for: ICAOIdentifier("KAUS")).first)

        #expect(notam.radiusNM == 7)
        #expect(notam.lowerLimitFt == 0)
        #expect(notam.upperLimitFt == 12_000)
        #expect(notam.endIsEstimated)
    }

    @Test func fallsBackToTheQueriedLocationWhenTheFeatureOmitsOne() async throws {
        let payload = Data("""
        {"status":"Success","data":{"geojson":[{"type":"Feature","geometry":null,
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

    // MARK: Spike arrest

    @Test func retriesOnceWhenTheSpikeArrestRejectsARequest() async throws {
        // Apigee answers 429 with policies.ratelimit.SpikeArrestViolation when
        // calls arrive faster than one a second — undocumented in the pack,
        // found only by calling staging.
        let http = NMSStubHTTPClient(payload: try fixture("nms_notams_kaus"), getFailures: [429])
        let notams = try await provider(http).notams(for: ICAOIdentifier("KAUS"))

        #expect(http.getURLs.count == 2)
        #expect(notams.count == 4)
    }

    @Test func givesUpAfterOneRetryRatherThanHanging() async throws {
        // A briefing that reports a gap beats one that never returns: the
        // route turns this into a 502 and the app falls back to its cache.
        let http = NMSStubHTTPClient(payload: try fixture("nms_notams_kaus"), getFailures: [429, 429])
        await #expect(throws: HTTPError.self) {
            _ = try await provider(http).notams(for: ICAOIdentifier("KAUS"))
        }
        #expect(http.getURLs.count == 2)
    }

    @Test func doesNotRetryFailuresThatRetryingCannotFix() async throws {
        // A 401 is a credential problem. Retrying it just spends another slot.
        let http = NMSStubHTTPClient(payload: try fixture("nms_notams_kaus"), getFailures: [401])
        await #expect(throws: HTTPError.self) {
            _ = try await provider(http).notams(for: ICAOIdentifier("KAUS"))
        }
        #expect(http.getURLs.count == 1)
    }

    @Test func pacesConcurrentFetchesInsteadOfBurstingThroughTheBudget() async throws {
        // NotamStore briefs airports four at a time. Four simultaneous fetches
        // must leave as a train, not a burst.
        let interval = 0.05
        let http = NMSStubHTTPClient(payload: try fixture("nms_notams_kaus"))
        let provider = provider(http, interval: interval)

        let started = Date()
        await withTaskGroup(of: Void.self) { group in
            for station in ["KAUS", "KDAL", "KHOU", "KSAT"] {
                group.addTask {
                    _ = try? await provider.notams(for: ICAOIdentifier(station))
                }
            }
        }
        let elapsed = Date().timeIntervalSince(started)

        // One token exchange plus four fetches is five slots; the first is
        // free, so four intervals must have elapsed.
        #expect(elapsed >= interval * 4)
        #expect(http.getURLs.count == 4)
    }

    @Test func concurrentFetchesShareOneTokenExchange() async throws {
        // Actor reentrancy means each concurrent caller can find the token
        // cache empty and start its own exchange. Four tokens would spend
        // four slots to no purpose.
        let http = NMSStubHTTPClient(payload: try fixture("nms_notams_kaus"))
        let provider = provider(http)

        await withTaskGroup(of: Void.self) { group in
            for station in ["KAUS", "KDAL", "KHOU", "KSAT"] {
                group.addTask {
                    _ = try? await provider.notams(for: ICAOIdentifier(station))
                }
            }
        }

        #expect(http.postCount == 1)
        #expect(http.getURLs.count == 4)
    }

    @Test func fitEnvironmentPointsAtTheTestHost() {
        #expect(NMSEnvironment.fit.apiBaseURL.host() == "api-fit.cgifederal-aim.com")
        #expect(NMSEnvironment.production.authURL.absoluteString == "https://api-nms.aim.faa.gov/v1/auth/token")
        // The token endpoint sits outside the /nmsapi prefix the data calls use.
        #expect(NMSEnvironment.staging.authURL.absoluteString == "https://api-staging.cgifederal-aim.com/v1/auth/token")
        #expect(NMSEnvironment.staging.apiBaseURL.absoluteString == "https://api-staging.cgifederal-aim.com/nmsapi")
    }
}

/// The Q-line coordinate format NMS publishes NOTAM centres in.
@Suite struct NMSCoordinateStringTests {
    @Test func parsesDegreesAndMinutes() throws {
        let centre = try #require(NMSNotam.coordinate(fromICAOString: "3939N04302E"))
        #expect(abs(centre.latitude - 39.65) < 0.000_01)
        #expect(abs(centre.longitude - 43.033_333) < 0.000_01)
    }

    @Test func parsesSecondsAndSouthWestHemispheres() throws {
        let centre = try #require(NMSNotam.coordinate(fromICAOString: "301145S0974030W"))
        #expect(abs(centre.latitude - (-30.195_833)) < 0.000_01)
        #expect(abs(centre.longitude - (-97.675)) < 0.000_01)
    }

    @Test func rejectsMalformedStringsRatherThanGuessing() {
        // A wrong centre is worse than no centre: it draws a circle over the
        // wrong ground.
        #expect(NMSNotam.coordinate(fromICAOString: "") == nil)
        #expect(NMSNotam.coordinate(fromICAOString: "3939N") == nil)
        #expect(NMSNotam.coordinate(fromICAOString: "39N043E") == nil)
        #expect(NMSNotam.coordinate(fromICAOString: "3999N04302E") == nil)
        #expect(NMSNotam.coordinate(fromICAOString: "9939N04302E") == nil)
        #expect(NMSNotam.coordinate(fromICAOString: "30.19N97.67W") == nil)
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
