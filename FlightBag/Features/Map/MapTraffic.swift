import MapKit
import UIKit
import FBGDL90

/// A traffic target annotation. Position and dynamics mutate in place
/// (like OwnshipAnnotation) so 1 Hz updates never rebuild the view.
final class TrafficAnnotation: NSObject, MKAnnotation {
    let address: UInt32
    dynamic var coordinate = CLLocationCoordinate2D()
    var trackDegrees: Double?
    var callsign: String = ""
    /// Altitude relative to ownship, in feet; nil when either is unknown.
    var relativeAltitudeFt: Int?
    var altitudeFt: Int?
    var verticalTrend: VerticalTrend = .level
    var isAirborne = true
    var isAlerted = false
    /// Bumped by `update(from:)` only when something the data block or symbol
    /// draws changed, so views skip redrawing identical reports.
    private(set) var reportVersion = 0

    enum VerticalTrend { case climbing, descending, level }

    init(address: UInt32) {
        self.address = address
    }
}

/// Chevron rotated to the target's track, tinted by alert state, with a
/// data block showing callsign, relative altitude, and climb/descent.
/// The symbol lives in its own image view so track rotation never turns
/// the data block sideways.
final class TrafficAnnotationView: MKAnnotationView {
    static let reuseId = "traffic"

    private let label = UILabel()
    private let symbolView = UIImageView()
    /// The annotation `reportVersion` this view last drew.
    private var drawnVersion = -1

    override var annotation: MKAnnotation? {
        didSet { configure() }
    }

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        displayPriority = .required
        zPriority = MKAnnotationViewZPriority(rawValue: 900)  // Below ownship (.max), above airports.
        collisionMode = .circle
        frame = CGRect(x: 0, y: 0, width: 22, height: 22)
        symbolView.frame = bounds
        symbolView.contentMode = .center
        addSubview(symbolView)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.numberOfLines = 2
        label.textColor = .label
        label.textAlignment = .left
        addSubview(label)
        configure()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Redraws only when the annotation's report changed since the last draw.
    /// Reassigning `annotation` instead reconfigured every traffic view on
    /// every map update, whatever triggered it.
    func refreshIfNeeded() {
        guard let traffic = annotation as? TrafficAnnotation, traffic.reportVersion != drawnVersion else { return }
        configure()
    }

    private func configure() {
        guard let traffic = annotation as? TrafficAnnotation else { return }
        drawnVersion = traffic.reportVersion
        let tint: UIColor = traffic.isAlerted ? .systemRed
            : traffic.isAirborne ? .systemOrange : .systemGray
        let symbol = traffic.isAirborne ? "arrowtriangle.up.fill" : "square.fill"
        let config = UIImage.SymbolConfiguration(pointSize: 15, weight: .black)
        symbolView.image = UIImage(systemName: symbol, withConfiguration: config)?
            .withTintColor(tint, renderingMode: .alwaysOriginal)

        label.text = dataBlock(for: traffic)
        label.sizeToFit()
        label.frame.origin = CGPoint(x: 24, y: -2)
    }

    private func dataBlock(for traffic: TrafficAnnotation) -> String {
        var lines: [String] = []
        if !traffic.callsign.isEmpty { lines.append(traffic.callsign) }
        var second = ""
        if let relative = traffic.relativeAltitudeFt {
            // Hundreds of feet, ForeFlight-style: +012 = 1200 ft above.
            let sign = relative >= 0 ? "+" : "−"
            second = String(format: "%@%03d", sign, abs(relative) / 100)
        } else if let altitude = traffic.altitudeFt {
            second = "\(altitude / 100)"
        }
        switch traffic.verticalTrend {
        case .climbing: second += " ↑"
        case .descending: second += " ↓"
        case .level: break
        }
        if !second.isEmpty { lines.append(second) }
        return lines.joined(separator: "\n")
    }

    /// Rotate the chevron to the target's ground track relative to the
    /// camera. Airborne targets only; on-ground squares stay upright.
    func updateRotation(map: MKMapView) {
        guard let traffic = annotation as? TrafficAnnotation, traffic.isAirborne else {
            symbolView.transform = .identity
            return
        }
        let track = traffic.trackDegrees ?? 0
        let relative = (track - map.camera.heading) * .pi / 180
        // The chevron art points north (up); no base offset needed.
        symbolView.transform = CGAffineTransform(rotationAngle: relative)
    }
}

extension TrafficAnnotation {
    /// Update mutable fields from a fresh report; `ownshipAltitude` drives
    /// the relative-altitude data block.
    func update(from report: GDL90Message.TrafficReport, ownshipAltitudeFt: Int?) {
        coordinate = CLLocationCoordinate2D(latitude: report.latitude, longitude: report.longitude)
        // Track is applied by rotation, not by a redraw.
        trackDegrees = report.trackDegrees

        let relative: Int? = if let altitude = report.altitudeFeet, let ownship = ownshipAltitudeFt {
            altitude - ownship
        } else {
            nil
        }
        let trend: VerticalTrend = switch report.verticalVelocityFpm {
        case let fpm? where fpm >= 500: .climbing
        case let fpm? where fpm <= -500: .descending
        default: .level
        }
        let changed = callsign != report.callsign || altitudeFt != report.altitudeFeet
            || isAirborne != report.airborne || isAlerted != report.alert
            || relativeAltitudeFt != relative || verticalTrend != trend
        guard changed else { return }
        callsign = report.callsign
        altitudeFt = report.altitudeFeet
        isAirborne = report.airborne
        isAlerted = report.alert
        relativeAltitudeFt = relative
        verticalTrend = trend
        reportVersion += 1
    }
}
