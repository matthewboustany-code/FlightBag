import Foundation
import Testing
import FBModels
import FBProviders
@testable import FlightBag

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func increment() { lock.withLock { calls += 1 } }
    var value: Int { lock.withLock { calls } }
}

private struct CountingWinds: WindsAloftProvider {
    let counter: CallCounter
    var fails = false

    func windsAloft(forecastHours: Int) async throws -> [WindsAloftStation] {
        counter.increment()
        if fails { throw URLError(.badServerResponse) }
        return [
            WindsAloftStation(identifier: "AUS", entries: [6000: .init(fromDegrees: 180, speedKt: 20)]),
            WindsAloftStation(identifier: "ZZZ", entries: [6000: .init(fromDegrees: 90, speedKt: 5)]),
        ]
    }
}

private struct CountingWeather: WeatherProvider {
    let counter: CallCounter

    func metar(for station: ICAOIdentifier) async throws -> Metar? {
        counter.increment()
        return Metar(station: station, raw: "\(station.rawValue) 131753Z 18010KT 10SM CLR 30/20 A3001")
    }
    func metars(for stations: [ICAOIdentifier]) async throws -> [Metar] { [] }
    func taf(for station: ICAOIdentifier) async throws -> Taf? { nil }
}

@Suite struct WindsAloftStoreTests {
    private let locate: @Sendable (String) async -> Coordinate? = { id in
        id == "AUS" ? Coordinate(latitude: 30.2, longitude: -97.7) : nil
    }

    @Test func reusesStationsWithinTheHour() async {
        let counter = CallCounter()
        let clock = CallCounter()  // seconds elapsed, advanced by hand
        let start = Date()
        let store = WindsAloftStore(provider: CountingWinds(counter: counter)) {
            start.addingTimeInterval(Double(clock.value))
        }

        let first = await store.stations(forecastHours: 6, locate: locate)
        let second = await store.stations(forecastHours: 6, locate: locate)
        #expect(first.map(\.station.identifier) == ["AUS"])  // ZZZ couldn't be placed
        #expect(second.count == 1)
        #expect(counter.value == 1)

        // A different period is a different product.
        _ = await store.stations(forecastHours: 12, locate: locate)
        #expect(counter.value == 2)

        for _ in 0..<3_601 { clock.increment() }
        _ = await store.stations(forecastHours: 6, locate: locate)
        #expect(counter.value == 3)
    }

    @Test func failuresAreNotCached() async {
        let counter = CallCounter()
        let store = WindsAloftStore(provider: CountingWinds(counter: counter, fails: true))
        #expect(await store.stations(forecastHours: 6, locate: locate).isEmpty)
        #expect(await store.stations(forecastHours: 6, locate: locate).isEmpty)
        #expect(counter.value == 2)
    }
}

@Suite(.serialized) struct WeatherFreshnessTests {
    @Test func recentInternetFetchIsNotRepeated() async {
        let counter = CallCounter()
        let store = WeatherStore(provider: CountingWeather(counter: counter))
        let station = ICAOIdentifier("KFRS\(Int.random(in: 0..<10_000))")
        let start = Date()

        _ = await store.weather(for: station, now: start)
        let again = await store.weather(for: station, now: start.addingTimeInterval(30))
        #expect(counter.value == 1)
        #expect(again.weather?.metar != nil)
        #expect(!again.isStale)

        _ = await store.weather(for: station, now: start.addingTimeInterval(WeatherStore.freshFor + 60))
        #expect(counter.value == 2)
    }
}
