import Foundation
import FBModels
import FBFISB

/// NOTAMs for an airport, with the same offline contract as `WeatherStore`:
/// the last good answer is kept on disk and served, age-stamped, when the
/// server is unreachable.
///
/// Unlike weather there is no direct-to-source fallback. The FAA's NOTAM
/// Management Service authenticates with OAuth client credentials that can't
/// ship in an app binary, so the only network path is the FlightBag server's
/// `/v1/airports/:id/notams` proxy. In the air, FIS-B fills the same cache.
actor NotamStore {
    enum Source: String, Codable, Sendable {
        case server
        case fisb
    }

    /// Why a station has no NOTAMs to show. An empty list is never rendered
    /// bare — "none published" and "couldn't ask" are different facts, and
    /// only one of them means the airspace is clear.
    enum Availability: Equatable {
        /// Fetched successfully (the list may still be empty).
        case available
        /// No server URL set in Settings.
        case noServerConfigured
        /// Server reached, but it has no FAA credentials.
        case serverMissingCredentials
        /// Server or FAA unreachable; anything shown came from cache.
        case unreachable
    }

    struct StationNotams: Codable, Sendable {
        var notams: [Notam]
        var fetchedAt: Date
        var source: Source?
    }

    struct Result: Sendable {
        var notams: [Notam]
        var fetchedAt: Date?
        var source: Source?
        var isStale: Bool
        var availability: Availability
    }

    private var cache: [String: StationNotams] = [:]
    private let cacheURL: URL
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        cacheURL = support.appendingPathComponent("FlightBag/notam-cache.json")
        if let data = try? Data(contentsOf: cacheURL),
           let stored = try? JSONDecoder().decode([String: StationNotams].self, from: data) {
            cache = stored
        }
    }

    /// Live NOTAMs when the server is reachable, otherwise the cached copy.
    func notams(for station: ICAOIdentifier) async -> Result {
        let key = station.rawValue.uppercased()

        guard let baseURL = ServerConfig.baseURL else {
            return result(for: key, availability: .noServerConfigured)
        }

        do {
            var request = URLRequest(url: baseURL.appendingPathComponent("v1/airports/\(key)/notams"))
            request.timeoutInterval = 15
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                // 502 means the server tried and the FAA said no — the cached
                // copy is the best answer available, not an empty list.
                return result(for: key, availability: .unreachable)
            }
            let decoded = try Self.decoder().decode(AirportNotamsResponse.self, from: data)
            guard decoded.configured else {
                return result(for: key, availability: .serverMissingCredentials)
            }
            let fresh = StationNotams(notams: decoded.notams, fetchedAt: Date(), source: .server)
            cache[key] = fresh
            persist()
            return Result(
                notams: sorted(fresh.notams),
                fetchedAt: fresh.fetchedAt,
                source: .server,
                isStale: false,
                availability: .available
            )
        } catch {
            return result(for: key, availability: .unreachable)
        }
    }

    /// Folds FIS-B uplink NOTAMs into the same cache the airport screen
    /// reads, so they appear in flight with no connectivity.
    ///
    /// The uplink carries only text — no geometry, no Q-code — so these merge
    /// alongside anything already fetched rather than replacing it, and a
    /// server-sourced NOTAM of the same number wins on detail.
    func ingestFISB(reports: [FISBTextReport], receivedAt: Date = Date()) {
        var touched = false
        for report in reports {
            guard let notam = report.toNotam() else { continue }
            let key = notam.location.rawValue.uppercased()
            guard !key.isEmpty else { continue }

            var entry = cache[key] ?? StationNotams(notams: [], fetchedAt: receivedAt)
            // The uplink rebroadcasts on a loop; never age-regress an entry.
            guard receivedAt >= entry.fetchedAt else { continue }
            if let index = entry.notams.firstIndex(where: { $0.id == notam.id }) {
                // Keep the richer server copy if we already have one.
                if entry.source == .fisb { entry.notams[index] = notam }
            } else {
                entry.notams.append(notam)
            }
            entry.fetchedAt = receivedAt
            entry.source = .fisb
            cache[key] = entry
            touched = true
        }
        if touched { persist() }
    }

    /// Seeds the cache for simulator verification (`-notamsDemoSeed YES`),
    /// so the UI can be exercised without credentials or a server.
    func seedDemoData() {
        let now = Date()
        cache["KAUS"] = StationNotams(
            notams: [
                Notam(
                    id: "01/005",
                    location: ICAOIdentifier("KAUS"),
                    text: "TWY A CLSD BTN TWY B AND TWY F",
                    classification: "DOMESTIC",
                    effectiveStart: now.addingTimeInterval(-86_400),
                    effectiveEnd: now.addingTimeInterval(86_400 * 30),
                    qCode: "QMXLC",
                    coordinate: Coordinate(latitude: 30.1945, longitude: -97.6699),
                    radiusNM: 5
                ),
                Notam(
                    id: "01/006",
                    location: ICAOIdentifier("KAUS"),
                    text: "OBST CRANE ERECTED 1.2NM SW APCH END RWY 18L (ASR 1234567) 620FT AGL",
                    classification: "DOMESTIC",
                    effectiveStart: now.addingTimeInterval(-86_400 * 14),
                    endIsEstimated: true,
                    qCode: "QOBCE",
                    coordinate: Coordinate(latitude: 30.18, longitude: -97.69),
                    radiusNM: 3,
                    lowerLimitFt: 0,
                    upperLimitFt: 1_000
                ),
                Notam(
                    id: "01/007",
                    location: ICAOIdentifier("KAUS"),
                    text: "RWY 18R/36L CLSD",
                    classification: "DOMESTIC",
                    effectiveStart: now.addingTimeInterval(-3_600),
                    effectiveEnd: now.addingTimeInterval(3_600 * 6),
                    qCode: "QMRLC"
                ),
            ],
            fetchedAt: now,
            source: .server
        )
        persist()
    }

    // MARK: - Route briefing

    /// NOTAMs for every airport along a route, in route order.
    ///
    /// Only airports are queried. Fixes and navaids have no NOTAM location of
    /// their own — the enroute notices that matter near them are area NOTAMs,
    /// which need the radius search this deliberately doesn't do yet.
    func briefing(for stations: [ICAOIdentifier]) async -> [StationBriefing] {
        // Preserve route order while collapsing a station that appears twice
        // (a round trip, or a departure that is also an alternate).
        var ordered: [String] = []
        for station in stations {
            // Trim first: a half-typed "From" field is whitespace, not an
            // airport, and would otherwise be briefed as one.
            let key = station.rawValue.trimmingCharacters(in: .whitespaces).uppercased()
            guard !key.isEmpty, !ordered.contains(key) else { continue }
            ordered.append(key)
        }
        guard !ordered.isEmpty else { return [] }

        // Bounded concurrency: a 12-leg route must not open 12 sockets at
        // once, and the server caches per station anyway.
        var results: [String: Result] = [:]
        let batchSize = 4
        for batch in stride(from: 0, to: ordered.count, by: batchSize).map({
            Array(ordered[$0..<min($0 + batchSize, ordered.count)])
        }) {
            await withTaskGroup(of: (String, Result).self) { group in
                for key in batch {
                    group.addTask { [self] in
                        (key, await notams(for: ICAOIdentifier(key)))
                    }
                }
                for await (key, result) in group {
                    results[key] = result
                }
            }
        }

        return ordered.compactMap { key in
            guard let result = results[key] else { return nil }
            return StationBriefing(station: ICAOIdentifier(key), result: result)
        }
    }

    struct StationBriefing: Sendable, Identifiable {
        var station: ICAOIdentifier
        var result: Result

        var id: String { station.rawValue }
    }

    // MARK: - Test hooks

    #if DEBUG
    func removeAllForTesting() {
        cache.removeAll()
        persist()
    }

    func cachedForTesting(_ station: String) -> StationNotams? {
        cache[station.uppercased()]
    }

    func seedForTesting(_ station: String, notams: [Notam], source: Source, fetchedAt: Date = Date()) {
        cache[station.uppercased()] = StationNotams(notams: notams, fetchedAt: fetchedAt, source: source)
        persist()
    }
    #endif

    private func result(for key: String, availability: Availability) -> Result {
        guard let entry = cache[key] else {
            return Result(notams: [], fetchedAt: nil, source: nil, isStale: false, availability: availability)
        }
        return Result(
            notams: sorted(entry.notams),
            fetchedAt: entry.fetchedAt,
            source: entry.source,
            isStale: true,
            availability: availability
        )
    }

    /// Active first, then by start time newest-first. Expired NOTAMs stay in
    /// the list rather than being filtered out — the server may be minutes
    /// stale, and a pilot deciding something is over should see it say so.
    private func sorted(_ notams: [Notam], now: Date = Date()) -> [Notam] {
        notams.sorted { lhs, rhs in
            let lhsActive = lhs.isActive(at: now)
            let rhsActive = rhs.isActive(at: now)
            if lhsActive != rhsActive { return lhsActive }
            let lhsStart = lhs.effectiveStart ?? .distantPast
            let rhsStart = rhs.effectiveStart ?? .distantPast
            if lhsStart != rhsStart { return lhsStart > rhsStart }
            return lhs.id < rhs.id
        }
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }
}

/// Mirrors the server's `AirportNotamsResponse`.
struct AirportNotamsResponse: Decodable, Sendable {
    let station: ICAOIdentifier
    let configured: Bool
    let notams: [Notam]
}

extension FISBTextReport {
    /// A FIS-B NOTAM record as a `Notam`.
    ///
    /// The conversion lives here rather than in FBFISB because that target is
    /// deliberately standalone — it decodes bytes and knows nothing about
    /// FBModels. Only text survives the uplink: no geometry, no Q-code, no
    /// end time, so validity is left unstated (which `isActive` reads as "in
    /// force", the safe direction for a notice received in flight).
    func toNotam() -> Notam? {
        guard kind.isNotam else { return nil }
        let station = station.trimmingCharacters(in: .whitespaces).uppercased()
        guard !station.isEmpty else { return nil }

        // Text arrives as "KAUS 01/005 TWY A CLSD" — station, then the NOTAM
        // number, then the body.
        var tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        if tokens.first?.uppercased() == station { tokens.removeFirst() }

        let number: String
        if let first = tokens.first, Self.looksLikeNotamNumber(first) {
            number = first
            tokens.removeFirst()
        } else {
            // No parseable number: key on the text so repeated uplinks of the
            // same notice collapse instead of piling up.
            number = "\(kind.rawValue)-\(abs(text.hashValue))"
        }

        let body = tokens.joined(separator: " ")
        guard !body.isEmpty else { return nil }

        return Notam(
            id: number,
            location: ICAOIdentifier(station),
            text: body,
            classification: kind.rawValue,
            endIsEstimated: true
        )
    }

    /// NOTAM numbers look like "01/005" or "A0123/26".
    private static func looksLikeNotamNumber(_ token: String) -> Bool {
        guard token.contains("/") else { return false }
        return token.contains(where: \.isNumber)
    }
}
