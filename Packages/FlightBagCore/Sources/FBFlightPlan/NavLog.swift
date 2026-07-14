import Foundation
import FBModels

/// One leg of a navigation log.
public struct NavLogLeg: Sendable, Hashable, Identifiable {
    public var id: Int
    public var from: ResolvedWaypoint
    public var to: ResolvedWaypoint
    public var distanceNM: Double
    /// Initial great-circle course, degrees true.
    public var courseTrue: Double
    /// Wind applied to this leg (direction the wind is from, degrees true).
    public var windFromDegrees: Double?
    public var windSpeedKt: Double?
    public var groundSpeedKt: Double?
    public var eteSeconds: Double?
    public var fuelGallons: Double?
    public var cumulativeDistanceNM: Double
    public var cumulativeEteSeconds: Double?
}

public struct NavLog: Sendable, Hashable {
    public var legs: [NavLogLeg]
    public var totalDistanceNM: Double
    public var totalEteSeconds: Double?
    public var totalFuelGallons: Double?

    public init(legs: [NavLogLeg], totalDistanceNM: Double, totalEteSeconds: Double?, totalFuelGallons: Double?) {
        self.legs = legs
        self.totalDistanceNM = totalDistanceNM
        self.totalEteSeconds = totalEteSeconds
        self.totalFuelGallons = totalFuelGallons
    }
}

/// Wind sampled at a location, e.g. from the winds-aloft forecast nearest a
/// leg's midpoint at the planned cruising altitude.
public struct LegWind: Sendable, Hashable {
    public var fromDegrees: Double
    public var speedKt: Double

    public init(fromDegrees: Double, speedKt: Double) {
        self.fromDegrees = fromDegrees
        self.speedKt = speedKt
    }
}

public enum NavLogBuilder {
    /// Build a navlog over the route's flown waypoint sequence. ETE and fuel
    /// stay nil when performance figures are missing so the UI can show
    /// distance-only logs for flights without an aircraft profile.
    public static func build(
        route: ParsedRoute,
        cruiseTASKt: Double? = nil,
        fuelBurnGPH: Double? = nil,
        wind: (Coordinate) -> LegWind? = { _ in nil }
    ) -> NavLog {
        let waypoints = route.waypoints
        var legs: [NavLogLeg] = []
        var cumulativeDistance = 0.0
        var cumulativeEte: Double? = 0

        for (index, pair) in zip(waypoints, waypoints.dropFirst()).enumerated() {
            let (from, to) = pair
            let distance = NavMath.distanceNM(from: from.coordinate, to: to.coordinate)
            let course = NavMath.initialBearing(from: from.coordinate, to: to.coordinate)
            let midpoint = Coordinate(
                latitude: (from.coordinate.latitude + to.coordinate.latitude) / 2,
                longitude: (from.coordinate.longitude + to.coordinate.longitude) / 2
            )
            let legWind = wind(midpoint)

            var groundSpeed: Double?
            if let tas = cruiseTASKt, tas > 0 {
                if let legWind {
                    groundSpeed = NavMath.groundSpeed(
                        tasKt: tas,
                        courseDegrees: course,
                        windFromDegrees: legWind.fromDegrees,
                        windSpeedKt: legWind.speedKt
                    )
                } else {
                    groundSpeed = tas
                }
            }
            let ete = groundSpeed.flatMap { NavMath.ete(distanceNM: distance, groundSpeedKt: $0) }
            let fuel: Double?
            if let ete, let burn = fuelBurnGPH, burn > 0 {
                fuel = ete / 3600 * burn
            } else {
                fuel = nil
            }

            cumulativeDistance += distance
            if let ete, let running = cumulativeEte {
                cumulativeEte = running + ete
            } else {
                cumulativeEte = nil
            }

            legs.append(NavLogLeg(
                id: index,
                from: from,
                to: to,
                distanceNM: distance,
                courseTrue: course,
                windFromDegrees: legWind?.fromDegrees,
                windSpeedKt: legWind?.speedKt,
                groundSpeedKt: groundSpeed,
                eteSeconds: ete,
                fuelGallons: fuel,
                cumulativeDistanceNM: cumulativeDistance,
                cumulativeEteSeconds: cumulativeEte
            ))
        }

        return NavLog(
            legs: legs,
            totalDistanceNM: cumulativeDistance,
            totalEteSeconds: legs.isEmpty ? nil : cumulativeEte,
            totalFuelGallons: legs.compactMap(\.fuelGallons).isEmpty ? nil : legs.compactMap(\.fuelGallons).reduce(0, +)
        )
    }
}
