import Foundation
import Observation
import FBModels
import FBProviders

/// Fetches and caches map advisories (TFRs, SIGMETs/AIRMETs, G-AIRMETs).
/// Each product degrades independently — a TFR outage must not blank the
/// SIGMET layer, and vice versa.
@Observable
@MainActor
final class AdvisoryStore {
    private(set) var airSigmets: [WeatherAdvisory] = []
    private(set) var gAirmets: [GraphicalAirmet] = []
    private(set) var tfrs: [TemporaryFlightRestriction] = []
    private(set) var lastRefresh: Date?
    private(set) var isRefreshing = false
    private(set) var lastError: String?
    /// Bumped whenever data changes so the map can rebuild overlays cheaply.
    private(set) var dataVersion = 0

    private let advisoryProvider: any AdvisoryProvider
    private let tfrProvider: any TFRProviding

    init(
        advisoryProvider: any AdvisoryProvider = AviationWeatherGovProvider(),
        tfrProvider: any TFRProviding = FAATFRProvider()
    ) {
        self.advisoryProvider = advisoryProvider
        self.tfrProvider = tfrProvider
    }

    func refreshIfStale(maxAge: TimeInterval = 10 * 60) async {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < maxAge { return }
        await refresh()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        async let sigmetsResult = try? advisoryProvider.airSigmets()
        async let airmetsResult = try? advisoryProvider.graphicalAirmets()
        async let tfrsResult = try? tfrProvider.activeTFRs()

        let (sigmets, airmets, tfrs) = await (sigmetsResult, airmetsResult, tfrsResult)
        let now = Date()

        if let sigmets {
            airSigmets = sigmets.filter { $0.validTo > now }
        }
        if let airmets {
            gAirmets = airmets.filter { $0.expireTime > now }
        }
        if let tfrs {
            self.tfrs = tfrs.filter { $0.expire.map { $0 > now } ?? true }
        }

        let failures = [
            sigmets == nil ? "SIGMETs" : nil,
            airmets == nil ? "G-AIRMETs" : nil,
            tfrs == nil ? "TFRs" : nil,
        ].compactMap(\.self)
        lastError = failures.isEmpty ? nil : "Couldn't refresh \(failures.joined(separator: ", "))"

        lastRefresh = now
        dataVersion += 1
    }
}
