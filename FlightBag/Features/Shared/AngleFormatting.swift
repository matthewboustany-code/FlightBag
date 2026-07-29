import Foundation

/// Formatting for the two angles that appear all over an EFB — courses and
/// magnetic variation — kept in one place so the navlog and the airport page
/// cannot drift into rendering them differently.
///
/// Neither is a unit conversion, so neither belongs on `UnitPreferences`:
/// degrees are degrees under every jurisdiction. Only the presentation is
/// conventional.
enum AngleFormat {
    /// Courses are conventionally three digits — 007°, not 7° — and wrap to
    /// 0..<360 so a computed value can be handed straight in.
    static func course(_ degrees: Double) -> String {
        var rounded = Int(degrees.rounded()) % 360
        if rounded < 0 { rounded += 360 }
        return String(format: "%03d", rounded)
    }

    /// Variation reads as a magnitude plus a hemisphere — "4°E", never "-4°".
    /// East positive, matching `Airport.magneticVariation` and the model.
    static func variation(_ degrees: Double) -> String {
        String(format: "%.0f°%@", abs(degrees), degrees >= 0 ? "E" : "W")
    }
}
