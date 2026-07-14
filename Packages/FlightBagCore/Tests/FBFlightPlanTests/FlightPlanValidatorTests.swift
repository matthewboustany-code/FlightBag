import Foundation
import Testing
import FBModels
@testable import FBFlightPlan

@Suite struct FlightPlanValidatorTests {
    private func validPlan() -> ICAOFlightPlan {
        ICAOFlightPlan(
            aircraftIdentification: "N123AB",
            flightRules: .ifr,
            aircraftType: "C172",
            wakeTurbulenceCategory: .light,
            equipment: "SBG",
            surveillanceEquipment: "EB1",
            departure: ICAOIdentifier("KAUS"),
            departureTime: Date(timeIntervalSinceNow: 3600),
            cruisingSpeed: "N0120",
            cruisingLevel: "A070",
            route: "CWK V163 LOA DCT",
            destination: ICAOIdentifier("KDAL"),
            totalEET: "0115",
            alternate1: ICAOIdentifier("KFTW"),
            fuelEndurance: "0430",
            personsOnBoard: 2
        )
    }

    @Test func validPlanHasNoErrors() {
        let issues = FlightPlanValidator.validate(validPlan())
        #expect(issues.filter { $0.severity == .error }.isEmpty)
    }

    @Test func missingRequiredFields() {
        let issues = FlightPlanValidator.validate(ICAOFlightPlan())
        let errorFields = Set(issues.filter { $0.severity == .error }.map(\.field))
        #expect(errorFields.contains(.aircraftIdentification))
        #expect(errorFields.contains(.aircraftType))
        #expect(errorFields.contains(.departure))
        #expect(errorFields.contains(.destination))
        #expect(errorFields.contains(.route))
        #expect(errorFields.contains(.totalEET))
    }

    @Test func speedAndLevelFormats() {
        var plan = validPlan()
        plan.cruisingSpeed = "120"
        plan.cruisingLevel = "7000"
        let fields = Set(FlightPlanValidator.validate(plan).map(\.field))
        #expect(fields.contains(.cruisingSpeed))
        #expect(fields.contains(.cruisingLevel))

        plan.cruisingSpeed = "M082"
        plan.cruisingLevel = "F350"
        let issues = FlightPlanValidator.validate(plan)
        #expect(!issues.contains { $0.field == .cruisingSpeed })
        #expect(!issues.contains { $0.field == .cruisingLevel })
    }

    @Test func eetValidation() {
        var plan = validPlan()
        plan.totalEET = "0175"  // invalid minutes
        #expect(FlightPlanValidator.validate(plan).contains { $0.field == .totalEET })
        plan.totalEET = "0000"
        #expect(FlightPlanValidator.validate(plan).contains { $0.field == .totalEET })
    }

    @Test func enduranceMustExceedEET() {
        var plan = validPlan()
        plan.fuelEndurance = "0100"  // less than EET 0115
        let issues = FlightPlanValidator.validate(plan)
        #expect(issues.contains { $0.field == .fuelEndurance && $0.severity == .warning })
    }

    @Test func ifrWithoutAlternateWarns() {
        var plan = validPlan()
        plan.alternate1 = nil
        let issues = FlightPlanValidator.validate(plan)
        #expect(issues.contains { $0.field == .alternate1 && $0.severity == .warning })
    }

    @Test func secondAlternateRequiresFirst() {
        var plan = validPlan()
        plan.alternate1 = nil
        plan.alternate2 = ICAOIdentifier("KACT")
        #expect(FlightPlanValidator.validate(plan).contains { $0.field == .alternate2 && $0.severity == .error })
    }
}

@Suite struct NavMathTests {
    @Test func jfkToLaxDistance() {
        let jfk = Coordinate(latitude: 40.6399, longitude: -73.7787)
        let lax = Coordinate(latitude: 33.9425, longitude: -118.4081)
        let distance = NavMath.distanceNM(from: jfk, to: lax)
        #expect(abs(distance - 2145) < 20)
    }

    @Test func initialBearingEastward() {
        let a = Coordinate(latitude: 30, longitude: -97)
        let b = Coordinate(latitude: 30, longitude: -96)
        let bearing = NavMath.initialBearing(from: a, to: b)
        #expect(abs(bearing - 90) < 1)
    }

    @Test func groundSpeedWithHeadAndTailwind() {
        // Direct headwind of 20 kt at 120 TAS.
        let head = NavMath.groundSpeed(tasKt: 120, courseDegrees: 360, windFromDegrees: 360, windSpeedKt: 20)
        #expect(abs(head - 100) < 0.1)
        // Direct tailwind.
        let tail = NavMath.groundSpeed(tasKt: 120, courseDegrees: 360, windFromDegrees: 180, windSpeedKt: 20)
        #expect(abs(tail - 140) < 0.1)
    }

    @Test func eteCalculation() {
        let ete = NavMath.ete(distanceNM: 120, groundSpeedKt: 120)
        #expect(ete == 3600)
        #expect(NavMath.ete(distanceNM: 100, groundSpeedKt: 0) == nil)
    }
}

@Suite struct RouteParserTests {
    struct FakeResolver: WaypointResolving {
        let waypoints: [String: ResolvedWaypoint]
        let airways: [String: [ResolvedWaypoint]]

        func resolveWaypoint(identifier: String) async throws -> ResolvedWaypoint? {
            waypoints[identifier]
        }

        func isAirway(identifier: String) async throws -> Bool {
            airways[identifier] != nil
        }

        func airwayPoints(identifier: String) async throws -> [ResolvedWaypoint] {
            airways[identifier] ?? []
        }
    }

    @Test func parsesMixedRoute() async throws {
        let resolver = FakeResolver(
            waypoints: [
                "KAUS": ResolvedWaypoint(identifier: "KAUS", coordinate: Coordinate(latitude: 30.19, longitude: -97.67), kind: .airport),
                "CWK": ResolvedWaypoint(identifier: "CWK", coordinate: Coordinate(latitude: 30.38, longitude: -97.53), kind: .navaid),
                "KDAL": ResolvedWaypoint(identifier: "KDAL", coordinate: Coordinate(latitude: 32.85, longitude: -96.85), kind: .airport),
            ],
            airways: ["V163": []]
        )
        let parsed = try await RouteParser(resolver: resolver).parse("KAUS CWK V163 BOGUS DCT KDAL")

        #expect(parsed.waypoints.map(\.identifier) == ["KAUS", "CWK", "KDAL"])
        #expect(parsed.unresolvedIdentifiers == ["BOGUS"])
        #expect(parsed.elements.contains(.airway("V163", via: [])))
        #expect(parsed.elements.contains(.direct))
        #expect(parsed.distanceNM > 100)
    }

    @Test func expandsAirwayBetweenEntryAndExit() async throws {
        func wp(_ id: String, _ lat: Double, _ lon: Double, _ kind: ResolvedWaypoint.Kind = .fix) -> ResolvedWaypoint {
            ResolvedWaypoint(identifier: id, coordinate: Coordinate(latitude: lat, longitude: lon), kind: kind)
        }
        let airwayPoints = [
            wp("MAM", 25.9, -97.4, .navaid),
            wp("GROSZ", 26.4, -97.5),
            wp("BRO", 25.9, -97.4, .navaid),
            wp("CWK", 30.38, -97.53, .navaid),
            wp("SOLDO", 31.0, -97.4),
            wp("LOA", 31.6, -97.2, .navaid),
            wp("YEAGR", 32.2, -97.0),
        ]
        let resolver = FakeResolver(
            waypoints: [
                "CWK": wp("CWK", 30.38, -97.53, .navaid),
                "LOA": wp("LOA", 31.6, -97.2, .navaid),
            ],
            airways: ["V163": airwayPoints]
        )

        // Forward: entry before exit on the airway.
        let forward = try await RouteParser(resolver: resolver).parse("CWK V163 LOA")
        #expect(forward.waypoints.map(\.identifier) == ["CWK", "SOLDO", "LOA"])

        // Reverse: flown against the airway's published direction.
        let reverse = try await RouteParser(resolver: resolver).parse("LOA V163 CWK")
        #expect(reverse.waypoints.map(\.identifier) == ["LOA", "SOLDO", "CWK"])
    }

    @Test func airwayWithoutBracketingWaypointsStaysUnexpanded() async throws {
        let resolver = FakeResolver(
            waypoints: [:],
            airways: ["V163": [ResolvedWaypoint(identifier: "CWK", coordinate: Coordinate(latitude: 30, longitude: -97), kind: .navaid)]]
        )
        let parsed = try await RouteParser(resolver: resolver).parse("V163")
        #expect(parsed.elements == [.airway("V163", via: [])])
    }
}

@Suite struct NavLogBuilderTests {
    private func route() -> ParsedRoute {
        func wp(_ id: String, _ lat: Double, _ lon: Double) -> ResolvedWaypoint {
            ResolvedWaypoint(identifier: id, coordinate: Coordinate(latitude: lat, longitude: lon), kind: .fix)
        }
        return ParsedRoute(elements: [
            .waypoint(wp("KAUS", 30.19, -97.67)),
            .waypoint(wp("CWK", 30.38, -97.53)),
            .waypoint(wp("KDAL", 32.85, -96.85)),
        ])
    }

    @Test func distanceOnlyWithoutPerformance() {
        let log = NavLogBuilder.build(route: route())
        #expect(log.legs.count == 2)
        #expect(log.totalDistanceNM > 150)
        #expect(log.totalEteSeconds == nil)
        #expect(log.totalFuelGallons == nil)
    }

    @Test func eteAndFuelWithProfile() throws {
        let log = NavLogBuilder.build(route: route(), cruiseTASKt: 120, fuelBurnGPH: 9)
        let total = try #require(log.totalEteSeconds)
        // ~160 NM at 120 kt ≈ 80 min.
        #expect(total > 60 * 60 && total < 100 * 60)
        let fuel = try #require(log.totalFuelGallons)
        #expect(abs(fuel - (total / 3600 * 9)) < 0.01)
        #expect(log.legs.last?.cumulativeDistanceNM == log.totalDistanceNM)
    }

    @Test func headwindSlowsLeg() {
        let still = NavLogBuilder.build(route: route(), cruiseTASKt: 120)
        let wind = NavLogBuilder.build(route: route(), cruiseTASKt: 120) { _ in
            LegWind(fromDegrees: 20, speedKt: 30) // roughly on the nose for a NNE course
        }
        #expect(wind.totalEteSeconds! > still.totalEteSeconds!)
    }

    @Test func parsesLatLonWaypoints() {
        let wholeDegrees = RouteParser.parseLatLon("46N078W")
        #expect(wholeDegrees == Coordinate(latitude: 46, longitude: -78))

        let withMinutes = RouteParser.parseLatLon("4620N07805W")
        #expect(withMinutes != nil)
        if let coordinate = withMinutes {
            #expect(abs(coordinate.latitude - (46 + 20.0 / 60)) < 0.0001)
            #expect(abs(coordinate.longitude - -(78 + 5.0 / 60)) < 0.0001)
        }

        #expect(RouteParser.parseLatLon("KAUS") == nil)
        #expect(RouteParser.parseLatLon("9990N07805W") == nil)
    }
}
