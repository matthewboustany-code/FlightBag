import Foundation
import FBModels

/// Great-circle navigation math. Inputs/outputs use nautical miles, degrees
/// true, and knots.
public enum NavMath {
    /// Mean Earth radius in nautical miles.
    public static let earthRadiusNM = 3440.065

    public static func distanceNM(from a: Coordinate, to b: Coordinate) -> Double {
        let lat1 = radians(a.latitude), lat2 = radians(b.latitude)
        let dLat = radians(b.latitude - a.latitude)
        let dLon = radians(b.longitude - a.longitude)
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadiusNM * asin(min(1, sqrt(h)))
    }

    /// Initial great-circle bearing in degrees true, 0..<360.
    public static func initialBearing(from a: Coordinate, to b: Coordinate) -> Double {
        let lat1 = radians(a.latitude), lat2 = radians(b.latitude)
        let dLon = radians(b.longitude - a.longitude)
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let bearing = degrees(atan2(y, x))
        return bearing < 0 ? bearing + 360 : bearing
    }

    /// Apply magnetic variation to a true course, east positive — the sign
    /// convention `Airport.magneticVariation` and `WorldMagneticModel` both
    /// use. Result is normalised to 0..<360.
    public static func magneticCourse(trueCourse: Double, variation: Double) -> Double {
        let course = (trueCourse - variation).truncatingRemainder(dividingBy: 360)
        return course < 0 ? course + 360 : course
    }

    /// Estimated time en route.
    public static func ete(distanceNM: Double, groundSpeedKt: Double) -> TimeInterval? {
        guard groundSpeedKt > 0 else { return nil }
        return distanceNM / groundSpeedKt * 3600
    }

    /// Ground speed given true airspeed, course, and wind (direction the wind
    /// is *from*, degrees true).
    public static func groundSpeed(tasKt: Double, courseDegrees: Double, windFromDegrees: Double, windSpeedKt: Double) -> Double {
        let relative = radians(windFromDegrees - courseDegrees)
        let headwind = windSpeedKt * cos(relative)
        let crosswind = windSpeedKt * sin(relative)
        let along = sqrt(max(0, tasKt * tasKt - crosswind * crosswind))
        return along - headwind
    }

    private static func radians(_ deg: Double) -> Double { deg * .pi / 180 }
    private static func degrees(_ rad: Double) -> Double { rad * 180 / .pi }
}
