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

/// Shared styling for annotation identifier labels: a white halo keeps the
/// lettering legible over dense chart ink, and a symbol-above-label layout
/// that sizes the view's bounds around both so MapKit collision declutters
/// the label, not just the symbol.
enum MapLabelStyle {
    static func halo(_ text: String, font: UIFont, color: UIColor) -> NSAttributedString {
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.white.withAlphaComponent(0.9)
        shadow.shadowBlurRadius = 2
        // Negative strokeWidth = stroke AND fill.
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .strokeColor: UIColor.white,
            .strokeWidth: -3.5,
            .shadow: shadow,
        ])
    }

    /// Centers the symbol over `coordinate` (via `centerOffset`) with the
    /// label directly beneath, and expands the view's bounds to contain both.
    static func layoutSymbolAboveLabel(in view: MKAnnotationView, symbol: UIImageView, label: UILabel, spacing: CGFloat = 1) {
        let symbolSize = symbol.frame.size
        let labelSize = label.frame.size
        let width = max(symbolSize.width, labelSize.width)
        let height = symbolSize.height + spacing + labelSize.height
        view.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        symbol.frame.origin = CGPoint(x: (width - symbolSize.width) / 2, y: 0)
        label.frame.origin = CGPoint(x: (width - labelSize.width) / 2, y: symbolSize.height + spacing)
        view.centerOffset = CGPoint(x: 0, y: (height - symbolSize.height) / 2)
    }
}

/// Chart-style waypoint symbol with the identifier lettered underneath.
final class WaypointAnnotationView: MKAnnotationView {
    static let reuseId = "waypoint"

    private let symbolView = UIImageView()
    private let label = UILabel()

    override var annotation: MKAnnotation? {
        didSet { configure() }
    }

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        addSubview(symbolView)
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
        let config = UIImage.SymbolConfiguration(pointSize: isNavaid ? 13 : 10, weight: .bold)
        symbolView.image = UIImage(
            systemName: isNavaid ? "hexagon" : "triangle",
            withConfiguration: config
        )?.withTintColor(isNavaid ? .systemIndigo : .darkGray, renderingMode: .alwaysOriginal)
        symbolView.sizeToFit()

        // Fixed dark ink (not .label): the white halo is the contrast layer,
        // and dark-mode .label would turn white-on-white.
        label.attributedText = MapLabelStyle.halo(
            annotation.waypoint.identifier,
            font: .monospacedSystemFont(ofSize: 12, weight: .semibold),
            color: UIColor(white: 0.15, alpha: 1)
        )
        label.sizeToFit()

        MapLabelStyle.layoutSymbolAboveLabel(in: self, symbol: symbolView, label: label)
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
