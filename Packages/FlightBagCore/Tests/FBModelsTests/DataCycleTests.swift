import Foundation
import Testing
@testable import FBModels

@Suite struct DataCycleTests {
    private func utcDate(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @Test func epochCycleIdentity() {
        let cycle = DataCycle.current(at: utcDate(2024, 1, 26))
        #expect(cycle.id == "2401")
    }

    @Test func knownCycleBoundaries() {
        // AIRAC 2501 effective 2025-01-23, 2601 effective 2026-01-22.
        #expect(DataCycle.current(at: utcDate(2025, 1, 24)).id == "2501")
        #expect(DataCycle.current(at: utcDate(2026, 1, 23)).id == "2601")
        // Day before 2601 becomes effective we're still in 2025's last cycle.
        let priorCycle = DataCycle.current(at: utcDate(2026, 1, 21))
        #expect(priorCycle.year == 2025)
    }

    @Test func midYear2026() {
        // 2026-07-12 falls in cycle 2607 (effective 2026-07-09).
        let cycle = DataCycle.current(at: utcDate(2026, 7, 12))
        #expect(cycle.id == "2607")
        #expect(cycle.contains(utcDate(2026, 7, 12)))
    }

    @Test func parseRoundTrip() {
        let cycle = DataCycle.current(at: utcDate(2026, 7, 12))
        let parsed = DataCycle(id: cycle.id)
        #expect(parsed == cycle)
    }

    @Test func parseRejectsNonsense() {
        #expect(DataCycle(id: "9999") == nil)
        #expect(DataCycle(id: "26") == nil)
        #expect(DataCycle(id: "26AB") == nil)
    }

    @Test func nextCycleIsContiguous() {
        let cycle = DataCycle.current(at: utcDate(2026, 7, 12))
        let next = cycle.next()
        #expect(next.effectiveDate == cycle.expirationDate)
        #expect(next > cycle)
    }

    @Test func freshnessBuckets() {
        let cycle = DataCycle.current(at: utcDate(2026, 7, 12))
        #expect(cycle.freshness(at: cycle.effectiveDate.addingTimeInterval(86400)) == .current)
        #expect(cycle.freshness(at: cycle.expirationDate.addingTimeInterval(-86400)) == .expiring)
        #expect(cycle.freshness(at: cycle.expirationDate.addingTimeInterval(86400)) == .expired)
        #expect(cycle.freshness(at: cycle.effectiveDate.addingTimeInterval(-86400)) == .notYetEffective)
    }
}

@Suite struct FlightCategoryTests {
    @Test func categoryRules() {
        #expect(FlightCategory.from(ceilingFeet: nil, visibilitySM: 10) == .vfr)
        #expect(FlightCategory.from(ceilingFeet: 3000, visibilitySM: 10) == .mvfr)
        #expect(FlightCategory.from(ceilingFeet: 900, visibilitySM: 10) == .ifr)
        #expect(FlightCategory.from(ceilingFeet: 400, visibilitySM: 10) == .lifr)
        #expect(FlightCategory.from(ceilingFeet: 5000, visibilitySM: 2) == .ifr)
        #expect(FlightCategory.from(ceilingFeet: 5000, visibilitySM: 0.5) == .lifr)
        #expect(FlightCategory.from(ceilingFeet: nil, visibilitySM: nil) == nil)
    }

    @Test func metarCeilingAndCategory() {
        let metar = Metar(
            station: ICAOIdentifier("KAUS"),
            raw: "KAUS 121753Z 18010KT 10SM SCT025 BKN008 28/22 A3002",
            visibilitySM: 10,
            clouds: [
                CloudLayer(cover: .sct, baseFeetAGL: 2500),
                CloudLayer(cover: .bkn, baseFeetAGL: 800),
            ]
        )
        #expect(metar.ceilingFeet == 800)
        #expect(metar.flightCategory == .ifr)
    }
}
