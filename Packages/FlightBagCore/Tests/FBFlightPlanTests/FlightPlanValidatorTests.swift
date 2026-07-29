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

/// Worldwide data makes navaid identifiers ambiguous — about a third of them
/// repeat across regions. The parser must give resolvers the positional
/// context needed to pick correctly.
@Suite struct AmbiguousIdentifierTests {
    /// Stands in for a worldwide navaid table: "LON" is both London (UK) and
    /// Londrina (Brazil), which is a real collision in OurAirports data.
    struct WorldResolver: WaypointResolving {
        let candidates: [String: [ResolvedWaypoint]]
        /// Records what anchor the parser supplied for each lookup.
        final class Log: @unchecked Sendable {
            var anchors: [String: Coordinate?] = [:]
        }
        let log = Log()

        func resolveWaypoint(identifier: String, near anchor: Coordinate?) async throws -> ResolvedWaypoint? {
            log.anchors[identifier] = anchor
            guard let options = candidates[identifier] else { return nil }
            guard let anchor else { return options.first }
            return options.min { a, b in
                squaredDistance(a.coordinate, anchor) < squaredDistance(b.coordinate, anchor)
            }
        }

        func isAirway(identifier: String) async throws -> Bool { false }

        private func squaredDistance(_ a: Coordinate, _ b: Coordinate) -> Double {
            let dLat = a.latitude - b.latitude
            let dLon = (a.longitude - b.longitude) * cos(b.latitude * .pi / 180)
            return dLat * dLat + dLon * dLon
        }
    }

    private func worldResolver() -> WorldResolver {
        WorldResolver(candidates: [
            "EGLL": [ResolvedWaypoint(identifier: "EGLL", coordinate: Coordinate(latitude: 51.47, longitude: -0.46), kind: .airport)],
            "SBLO": [ResolvedWaypoint(identifier: "SBLO", coordinate: Coordinate(latitude: -23.33, longitude: -51.13), kind: .airport)],
            "LON": [
                // Londrina first, so "take the first match" would be wrong.
                ResolvedWaypoint(identifier: "LON", name: "Londrina", coordinate: Coordinate(latitude: -23.33, longitude: -51.13), kind: .navaid),
                ResolvedWaypoint(identifier: "LON", name: "London", coordinate: Coordinate(latitude: 51.50, longitude: -0.46), kind: .navaid),
            ],
        ])
    }

    @Test func ambiguousNavaidResolvesNearThePrecedingPoint() async throws {
        let resolver = worldResolver()
        let route = try await RouteParser(resolver: resolver).parse("EGLL LON")

        guard case .waypoint(let resolved) = route.elements[1] else {
            Issue.record("expected LON to resolve")
            return
        }
        // Departing Heathrow, "LON" is London — not a navaid in Brazil.
        #expect(resolved.name == "London")
    }

    @Test func theSameTokenResolvesDifferentlyFromElsewhere() async throws {
        let resolver = worldResolver()
        let route = try await RouteParser(resolver: resolver).parse("SBLO LON")

        guard case .waypoint(let resolved) = route.elements[1] else {
            Issue.record("expected LON to resolve")
            return
        }
        #expect(resolved.name == "Londrina")
    }

    @Test func theFirstTokenHasNoAnchorAndLaterOnesDo() async throws {
        let resolver = worldResolver()
        _ = try await RouteParser(resolver: resolver).parse("EGLL LON")

        #expect(resolver.log.anchors["EGLL"] == .some(nil))
        // The anchor handed to LON is Heathrow's position.
        let anchor = resolver.log.anchors["LON"] ?? nil
        #expect(anchor?.latitude == 51.47)
    }

    @Test func latLonTokensAlsoAnchorTheNextLookup() async throws {
        let resolver = worldResolver()
        _ = try await RouteParser(resolver: resolver).parse("5130N00030W LON")

        let anchor = resolver.log.anchors["LON"] ?? nil
        #expect(anchor != nil)
        #expect((anchor?.latitude ?? 0) > 50)
    }
}

@Suite struct RouteParserTests {
    struct FakeResolver: WaypointResolving {
        let waypoints: [String: ResolvedWaypoint]
        let airways: [String: [ResolvedWaypoint]]

        func resolveWaypoint(identifier: String, near: Coordinate?) async throws -> ResolvedWaypoint? {
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

    // MARK: - Magnetic course

    /// 1 June 2026, so the variation figures below are pinned to a date rather
    /// than drifting with the clock and quietly loosening the test.
    private var fixedDate: Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        return utc.date(from: DateComponents(year: 2026, month: 6, day: 1))!
    }

    @Test func magneticCourseAppliesVariationAtTheLegStart() throws {
        let log = NavLogBuilder.build(route: route(), date: fixedDate)
        let leg = try #require(log.legs.first)

        let expected = WorldMagneticModel.wmm2025.declination(
            at: leg.from.coordinate,
            on: fixedDate
        )
        #expect(abs(leg.magneticVariation - expected) < 1e-9)
        #expect(abs(leg.courseMagnetic - (leg.courseTrue - expected)) < 1e-9)
        // Central Texas is a few degrees east in this era.
        #expect(leg.magneticVariation > 1 && leg.magneticVariation < 6)
    }

    /// The regression this exists for: before the model, variation came from
    /// the airport record, which is nil for every aerodrome OurAirports
    /// supplies — so a European navlog had no magnetic course at all.
    @Test func magneticCourseIsAvailableOutsideTheUS() throws {
        func wp(_ id: String, _ lat: Double, _ lon: Double) -> ResolvedWaypoint {
            ResolvedWaypoint(identifier: id, coordinate: Coordinate(latitude: lat, longitude: lon), kind: .fix)
        }
        let frankfurtToParis = ParsedRoute(elements: [
            .waypoint(wp("EDDF", 50.0333, 8.5706)),
            .waypoint(wp("LFPG", 49.0097, 2.5479)),
        ])

        let log = NavLogBuilder.build(route: frankfurtToParis, date: fixedDate)
        let leg = try #require(log.legs.first)
        #expect(log.magneticModelValidity == .valid)
        // Central Europe runs a little east of true in this era.
        #expect(leg.magneticVariation > 0 && leg.magneticVariation < 5)
        #expect(leg.courseMagnetic != leg.courseTrue)
        #expect(leg.courseMagnetic >= 0 && leg.courseMagnetic < 360)
    }

    /// Variation is a field, not an airport property. Taking the departure
    /// aerodrome's value for the whole route — the obvious shortcut — would be
    /// degrees wrong by the far end of a long one.
    @Test func variationIsComputedPerLegNotOncePerRoute() throws {
        func wp(_ id: String, _ lat: Double, _ lon: Double) -> ResolvedWaypoint {
            ResolvedWaypoint(identifier: id, coordinate: Coordinate(latitude: lat, longitude: lon), kind: .fix)
        }
        let transatlantic = ParsedRoute(elements: [
            .waypoint(wp("KJFK", 40.6398, -73.7789)),
            .waypoint(wp("EGLL", 51.4775, -0.4614)),
            .waypoint(wp("EDDF", 50.0333, 8.5706)),
        ])

        let log = NavLogBuilder.build(route: transatlantic, date: fixedDate)
        #expect(log.legs.count == 2)
        // New York sits ~12° west of true, London ~1° east.
        #expect(log.legs[0].magneticVariation < -8)
        #expect(log.legs[1].magneticVariation > 0)
        let spread = abs(log.legs[0].magneticVariation - log.legs[1].magneticVariation)
        #expect(spread > 10, "variation should swing across the Atlantic, got \(spread)°")
    }

    @Test func expiredMagneticModelIsFlaggedOnTheLog() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let pastExpiry = utc.date(from: DateComponents(year: 2031, month: 1, day: 1))!

        let log = NavLogBuilder.build(route: route(), date: pastExpiry)
        #expect(log.magneticModelValidity == .expired)
        // Still computed — a stale variation beats none, provided it is labelled.
        #expect(log.legs.allSatisfy { $0.courseMagnetic.isFinite })
    }

    @Test func magneticCourseWrapsThroughNorth() {
        #expect(abs(NavMath.magneticCourse(trueCourse: 5, variation: 10) - 355) < 1e-9)
        #expect(abs(NavMath.magneticCourse(trueCourse: 355, variation: -10) - 5) < 1e-9)
        #expect(abs(NavMath.magneticCourse(trueCourse: 90, variation: 10) - 80) < 1e-9)
        #expect(abs(NavMath.magneticCourse(trueCourse: 0, variation: 0) - 0) < 1e-9)
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

/// Rules that genuinely differ by state. ICAO field *formats* are universal
/// and covered above; these are the cases where giving US advice abroad would
/// be wrong.
@Suite struct FlightPlanJurisdictionTests {
    private func plan(departure: String, alternate: String?, level: String = "A070") -> ICAOFlightPlan {
        ICAOFlightPlan(
            aircraftIdentification: "N123AB",
            flightRules: .ifr,
            aircraftType: "C172",
            wakeTurbulenceCategory: .light,
            equipment: "SBG",
            surveillanceEquipment: "EB1",
            departure: ICAOIdentifier(departure),
            departureTime: Date(timeIntervalSinceNow: 3600),
            cruisingSpeed: "N0120",
            cruisingLevel: level,
            route: "DCT",
            destination: ICAOIdentifier("EDDM"),
            totalEET: "0115",
            alternate1: alternate.map { ICAOIdentifier($0) },
            fuelEndurance: "0430",
            personsOnBoard: 2
        )
    }

    private func message(_ issues: [ValidationIssue], _ field: ValidationIssue.Field) -> String? {
        issues.first { $0.field == field }?.message
    }

    @Test func alternateAdviceFollowsTheDepartureState() {
        let us = FlightPlanValidator.validate(plan(departure: "KAUS", alternate: nil))
        #expect(message(us, .alternate1)?.contains("1-2-3") == true)

        // The 1-2-3 rule is a US regulation; naming it to a pilot departing
        // Frankfurt would be actively wrong.
        let germany = FlightPlanValidator.validate(plan(departure: "EDDF", alternate: nil))
        #expect(message(germany, .alternate1)?.contains("1-2-3") == false)
        #expect(message(germany, .alternate1)?.contains("AIP") == true)

        let canada = FlightPlanValidator.validate(plan(departure: "CYYZ", alternate: nil))
        #expect(message(canada, .alternate1)?.contains("TC AIM") == true)
    }

    @Test func jurisdictionCanBeOverriddenExplicitly() {
        let issues = FlightPlanValidator.validate(
            plan(departure: "KAUS", alternate: nil),
            jurisdiction: .forCountry("DE")
        )
        #expect(message(issues, .alternate1)?.contains("1-2-3") == false)
    }

    @Test func altitudeAboveAFixedTransitionAltitudeWarns() {
        // A180 is 18,000 ft — a flight level in US and Canadian airspace.
        let us = FlightPlanValidator.validate(plan(departure: "KAUS", alternate: "KFTW", level: "A180"))
        #expect(message(us, .cruisingLevel)?.contains("flight level") == true)

        let below = FlightPlanValidator.validate(plan(departure: "KAUS", alternate: "KFTW", level: "A170"))
        #expect(message(below, .cruisingLevel) == nil)
    }

    @Test func noTransitionWarningWhereItVariesByAerodrome() {
        // Across most of Europe the transition altitude is per-aerodrome, so
        // there is nothing to check against — staying quiet beats guessing.
        let issues = FlightPlanValidator.validate(plan(departure: "EDDF", alternate: "EDDK", level: "A180"))
        #expect(message(issues, .cruisingLevel) == nil)
    }

    @Test func metricLevelsRemainValidEverywhere() {
        let issues = FlightPlanValidator.validate(plan(departure: "ZBAA", alternate: "ZSSS", level: "S1130"))
        #expect(issues.contains { $0.field == .cruisingLevel && $0.severity == .error } == false)
    }
}
