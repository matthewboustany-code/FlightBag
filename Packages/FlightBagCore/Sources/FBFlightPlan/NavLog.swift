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
    /// Magnetic variation at the start of the leg, degrees, east positive.
    public var magneticVariation: Double
    /// Initial course in degrees magnetic — the number actually flown.
    ///
    /// Evaluated at the leg's start point, the same instant `courseTrue`
    /// describes, so the pair stays coherent: this is the heading to set
    /// rolling out on course, not an average over the leg.
    public var courseMagnetic: Double
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
    /// Whether the magnetic model covers the flight's date.
    ///
    /// Carried once for the whole log rather than per leg: it is a property of
    /// the shipped model, not of any particular leg, and the UI needs to say
    /// "these magnetic courses are from an expired model" exactly once.
    public var magneticModelValidity: WorldMagneticModel.Validity

    public init(
        legs: [NavLogLeg],
        totalDistanceNM: Double,
        totalEteSeconds: Double?,
        totalFuelGallons: Double?,
        magneticModelValidity: WorldMagneticModel.Validity = .valid
    ) {
        self.legs = legs
        self.totalDistanceNM = totalDistanceNM
        self.totalEteSeconds = totalEteSeconds
        self.totalFuelGallons = totalFuelGallons
        self.magneticModelValidity = magneticModelValidity
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
    ///
    /// Magnetic variation is computed per leg from the World Magnetic Model
    /// rather than read off the departure airport: variation is a field, not
    /// an airport property, and it swings by tens of degrees over a long
    /// route. It is also the only way to get a magnetic course at all outside
    /// the US, where no aerodrome record carries one.
    ///
    /// `date` matters because variation drifts measurably year to year — pass
    /// the planned departure date rather than letting it default when one is
    /// known.
    public static func build(
        route: ParsedRoute,
        cruiseTASKt: Double? = nil,
        fuelBurnGPH: Double? = nil,
        date: Date = Date(),
        magneticModel: WorldMagneticModel = .wmm2025,
        wind: (Coordinate) -> LegWind? = { _ in nil }
    ) -> NavLog {
        let waypoints = route.waypoints
        var legs: [NavLogLeg] = []
        var cumulativeDistance = 0.0
        var cumulativeEte: Double? = 0
        var validity = WorldMagneticModel.Validity.valid

        for (index, pair) in zip(waypoints, waypoints.dropFirst()).enumerated() {
            let (from, to) = pair
            let distance = NavMath.distanceNM(from: from.coordinate, to: to.coordinate)
            let course = NavMath.initialBearing(from: from.coordinate, to: to.coordinate)
            let midpoint = Coordinate(
                latitude: (from.coordinate.latitude + to.coordinate.latitude) / 2,
                longitude: (from.coordinate.longitude + to.coordinate.longitude) / 2
            )
            let legWind = wind(midpoint)

            let magnetic = magneticModel.field(at: from.coordinate, on: date)
            validity = magnetic.validity
            let variation = magnetic.field.declination

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
                magneticVariation: variation,
                courseMagnetic: NavMath.magneticCourse(trueCourse: course, variation: variation),
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
            totalFuelGallons: legs.compactMap(\.fuelGallons).isEmpty ? nil : legs.compactMap(\.fuelGallons).reduce(0, +),
            magneticModelValidity: validity
        )
    }
}
