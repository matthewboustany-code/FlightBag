import Foundation
import MapKit
import UIKit
import FBModels

// Aeronautical vector layer: waypoints, airways, and airspace volumes drawn
// over the chart stack from the offline database + FAA airspace services.

// MARK: Waypoints

final class WaypointAnnotation: NSObject, MKAnnotation {
    let waypoint: AeroDatabase.MapWaypoint
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: waypoint.latitude, longitude: waypoint.longitude)
    }
    var title: String? { waypoint.identifier }

    init(waypoint: AeroDatabase.MapWaypoint) {
        self.waypoint = waypoint
    }
}

/// Chart-style waypoint symbol with the identifier lettered underneath.
final class WaypointAnnotationView: MKAnnotationView {
    static let reuseId = "waypoint"

    private let label = UILabel()

    override var annotation: MKAnnotation? {
        didSet { configure() }
    }

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        label.font = UIFont.monospacedSystemFont(ofSize: 9, weight: .semibold)
        label.textColor = .secondaryLabel
        addSubview(label)
        configure()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configure() {
        guard let annotation = annotation as? WaypointAnnotation else { return }
        let isNavaid: Bool
        if case .navaid = annotation.waypoint.kind {
            isNavaid = true
        } else {
            isNavaid = false
        }
        let config = UIImage.SymbolConfiguration(pointSize: isNavaid ? 11 : 8, weight: .bold)
        image = UIImage(
            systemName: isNavaid ? "hexagon" : "triangle",
            withConfiguration: config
        )?.withTintColor(isNavaid ? .systemIndigo : .darkGray, renderingMode: .alwaysOriginal)

        label.text = annotation.waypoint.identifier
        label.sizeToFit()
        label.frame.origin = CGPoint(x: -label.frame.width / 2 + (image?.size.width ?? 0) / 2, y: (image?.size.height ?? 0) + 1)
        displayPriority = isNavaid ? .defaultHigh : .defaultLow
        collisionMode = .rectangle
    }
}

// MARK: Airways

final class AirwayPolyline: MKPolyline {
    var ident = ""
    var isHigh = false

    static func make(_ line: AeroDatabase.AirwayLine) -> AirwayPolyline {
        var points = line.coordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        let polyline = AirwayPolyline(coordinates: &points, count: points.count)
        polyline.ident = line.ident
        polyline.isHigh = line.isHigh
        return polyline
    }
}

// MARK: Airspace

extension Airspace.Category {
    var strokeColor: UIColor {
        switch self {
        case .classB: .systemBlue
        // Sectional-convention magenta for Class C.
        case .classC: UIColor(red: 0.72, green: 0.13, blue: 0.52, alpha: 1)
        case .classD: .systemBlue
        case .restricted: .systemRed
        case .prohibited: .systemRed
        case .warning: .systemOrange
        }
    }

    /// Class D and SUA boundaries draw dashed, matching chart style.
    var isDashed: Bool {
        switch self {
        case .classD, .restricted, .warning: true
        case .classB, .classC, .prohibited: false
        }
    }

    var fillAlpha: CGFloat {
        switch self {
        case .prohibited: 0.14
        case .restricted: 0.08
        default: 0.05
        }
    }
}

extension AdvisoryPolygon {
    static func makeAirspace(ring: [Coordinate], airspace: Airspace) -> AdvisoryPolygon {
        var points = ring.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        let polygon = AdvisoryPolygon(coordinates: &points, count: points.count)
        polygon.strokeColor = airspace.category.strokeColor
        polygon.fillAlpha = airspace.category.fillAlpha
        polygon.isDashed = airspace.category.isDashed
        polygon.info = AdvisoryDisplayInfo(
            color: airspace.category.strokeColor,
            title: "\(airspace.name) · \(airspace.category.displayName)",
            subtitle: "\(airspace.lowerText) – \(airspace.upperText)",
            detail: airspace.timesOfUse.map { "Times of use: \($0)" } ?? ""
        )
        return polygon
    }
}
