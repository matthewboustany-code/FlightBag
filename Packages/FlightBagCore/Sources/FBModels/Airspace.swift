import Foundation

/// A controlled or special-use airspace volume for map display.
public struct Airspace: Codable, Sendable, Hashable, Identifiable {
    public enum Category: String, Codable, Sendable, CaseIterable {
        case classB
        case classC
        case classD
        case restricted
        case prohibited
        case warning
        /// ICAO Danger Area. Kept distinct from `.warning` rather than folded
        /// into it: the US uses Warning Areas over international waters, while
        /// most of the world publishes Danger Areas, and a pilot reading
        /// "Warning" on a European chart symbol would be reading the wrong
        /// designation.
        case danger

        public var displayName: String {
            switch self {
            case .classB: "Class B"
            case .classC: "Class C"
            case .classD: "Class D"
            case .restricted: "Restricted"
            case .prohibited: "Prohibited"
            case .warning: "Warning"
            case .danger: "Danger"
            }
        }
    }

    public var id: String
    public var name: String
    public var category: Category
    /// Altitude limits as published, e.g. "SFC" / "4,800 ft MSL" / "FL 180".
    public var lowerText: String
    public var upperText: String
    public var timesOfUse: String?
    /// Outer rings; most volumes are one polygon, shelves add more.
    public var polygons: [[Coordinate]]

    public init(
        id: String,
        name: String,
        category: Category,
        lowerText: String,
        upperText: String,
        timesOfUse: String? = nil,
        polygons: [[Coordinate]]
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.lowerText = lowerText
        self.upperText = upperText
        self.timesOfUse = timesOfUse
        self.polygons = polygons
    }
}
