import Foundation
import CoreLocation
import Observation

/// One ownship state sample, source-agnostic.
struct OwnshipPosition: Sendable {
    var coordinate: CLLocationCoordinate2D
    /// Ground track, degrees true; nil when stationary/unknown.
    var trackDegrees: Double?
    var groundSpeedKt: Double?
    var altitudeFeet: Double?
    var timestamp: Date
    /// Display name of the producing source ("GPS", "ADS-B").
    var sourceName: String
}

/// Ownship position abstraction. Phase 2 ships the CoreLocation
/// implementation; Phase 4 adds an ADS-B (GDL90) source that is preferred
/// when healthy, with automatic fallback to this one.
@MainActor
protocol PositionSource: AnyObject {
    var position: OwnshipPosition? { get }
    var isDenied: Bool { get }
    func activate()
}

@Observable
final class CoreLocationPositionSource: NSObject, PositionSource, CLLocationManagerDelegate {
    private(set) var position: OwnshipPosition?
    private(set) var isDenied = false

    private let manager = CLLocationManager()
    private var started = false

    func activate() {
        manager.delegate = self
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            isDenied = true
        default:
            startUpdates()
        }
    }

    private func startUpdates() {
        guard !started else { return }
        started = true
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .airborne
        manager.startUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            isDenied = false
            startUpdates()
        case .denied, .restricted:
            isDenied = true
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        position = OwnshipPosition(
            coordinate: location.coordinate,
            trackDegrees: location.course >= 0 ? location.course : nil,
            groundSpeedKt: location.speed >= 0 ? location.speed * 1.943844 : nil,
            altitudeFeet: location.verticalAccuracy > 0 ? location.altitude * 3.28084 : nil,
            timestamp: location.timestamp,
            sourceName: "GPS"
        )
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Keep the last fix; transient failures are common in flight.
    }
}
