import Foundation

/// A WGS84 coordinate. Deliberately not CoreLocation so it builds on Linux;
/// the app maps this to CLLocationCoordinate2D at the map boundary.
public struct Coordinate: Codable, Sendable, Hashable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}
