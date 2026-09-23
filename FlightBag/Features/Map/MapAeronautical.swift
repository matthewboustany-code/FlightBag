import Foundation
import MapKit
import UIKit
import FBModels

// Aeronautical vector layer: waypoints, airways, and airspace volumes drawn
// over the chart stack from the offline database + FAA airspace services.
//
// Everything here sits on top of a raster chart printed in the same blues
// and magentas the overlay would naturally use, so legibility comes from
// separation rather than hue: labels are opaque tags, symbols carry a white
// outline, and every line is cased in white. Without that, the overlay
// reads as more chart ink.

// MARK: Labels

/// Identifier label drawn as an opaque rounded tag.
///
/// A stroke/shadow halo was tried first and failed over sectional ink: the
/// white stroke sits on the glyph outline and eats half the fill, so thin
/// weights wash out, and the blurred shadow costs an offscreen pass per
/// annotation. The tag's background is a layer color (no masking), so it
/// renders in one pass.
final class MapTagLabel: UILabel {
    private static let insets = UIEdgeInsets(top: 1, left: 3, bottom: 1, right: 3)

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 3
        layer.borderWidth = 0.75
    }

    required init?(coder: NSCoder) { fatalError() }

    func setTag(_ text: String, font: UIFont, color: UIColor) {
        self.text = text
        self.font = font
        textColor = color
        layer.backgroundColor = UIColor.white.withAlphaComponent(0.88).cgColor
        layer.borderColor = color.withAlphaComponent(0.55).cgColor
        sizeToFit()
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: Self.insets))
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let fitted = super.sizeThatFits(size)
        return CGSize(
            width: ceil(fitted.width + Self.insets.left + Self.insets.right),
            height: ceil(fitted.height + Self.insets.top + Self.insets.bottom)
        )
    }
}

/// Shared layout for symbol-over-label annotations: sizes the view's bounds
/// around both so MapKit collision declutters the label, not just the symbol.
enum MapLabelStyle {
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

// MARK: Palette

/// Overlay ink, chosen to separate from sectional/enroute printing: deeper
/// and more saturated than the chart's own blues and magentas, and always
/// drawn with a white casing.
nonisolated enum AeroPalette {
    static let fix = UIColor(red: 0.16, green: 0.20, blue: 0.26, alpha: 1)
    static let vor = UIColor(red: 0.05, green: 0.22, blue: 0.55, alpha: 1)
    static let ndb = UIColor(red: 0.50, green: 0.22, blue: 0.08, alpha: 1)
    static let airwayLow = UIColor(red: 0.00, green: 0.42, blue: 0.50, alpha: 1)
    static let airwayHigh = UIColor(red: 0.36, green: 0.26, blue: 0.52, alpha: 1)
    static let casing = UIColor.white.withAlphaComponent(0.9)
}

// MARK: Waypoints

final class WaypointAnnotation: NSObject, MKAnnotation {
    let waypoint: AeroDatabase.MapWaypoint
    let coordinate: CLLocationCoordinate2D
    var title: String? { waypoint.identifier }

    init(waypoint: AeroDatabase.MapWaypoint) {
        self.waypoint = waypoint
        self.coordinate = CLLocationCoordinate2D(latitude: waypoint.latitude, longitude: waypoint.longitude)
    }
}

nonisolated extension AeroDatabase.MapWaypoint {
    nonisolated enum Symbol: Sendable { case fix, vor, ndb }

    var navaidType: String? {
        if case .navaid(let type) = kind { return type }
        return nil
    }

    var symbol: Symbol {
        guard case .navaid(let type) = kind else { return .fix }
        return (type ?? "").uppercased().contains("NDB") ? .ndb : .vor
    }
}

/// Pre-rendered waypoint symbols. Drawn once (not per view) with a white
/// outline so they stay visible over dark chart ink.
enum WaypointSymbols {
    static let fix = render(size: 12) { rect, ctx in
        let path = UIBezierPath()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.close()
        outline(path, ctx: ctx)
        AeroPalette.fix.setFill()
        path.fill()
    }

    static let vor = render(size: 16) { rect, ctx in
        let path = UIBezierPath()
        for i in 0..<6 {
            let angle = CGFloat(i) * .pi / 3
            let point = CGPoint(x: rect.midX + cos(angle) * rect.width / 2, y: rect.midY + sin(angle) * rect.height / 2)
            i == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        path.close()
        outline(path, ctx: ctx)
        UIColor.white.setFill()
        path.fill()
        AeroPalette.vor.setStroke()
        path.lineWidth = 2
        path.stroke()
        AeroPalette.vor.setFill()
        UIBezierPath(ovalIn: rect.insetBy(dx: rect.width * 0.38, dy: rect.height * 0.38)).fill()
    }

    static let ndb = render(size: 14) { rect, ctx in
        let path = UIBezierPath(ovalIn: rect)
        outline(path, ctx: ctx)
        UIColor.white.setFill()
        path.fill()
        AeroPalette.ndb.setStroke()
        path.lineWidth = 2
        path.stroke()
        AeroPalette.ndb.setFill()
        UIBezierPath(ovalIn: rect.insetBy(dx: rect.width * 0.36, dy: rect.height * 0.36)).fill()
    }

    static func image(for symbol: AeroDatabase.MapWaypoint.Symbol) -> UIImage {
        switch symbol {
        case .fix: fix
        case .vor: vor
        case .ndb: ndb
        }
    }

    static func color(for symbol: AeroDatabase.MapWaypoint.Symbol) -> UIColor {
        switch symbol {
        case .fix: AeroPalette.fix
        case .vor: AeroPalette.vor
        case .ndb: AeroPalette.ndb
        }
    }

    private static let outlineWidth: CGFloat = 3

    private static func outline(_ path: UIBezierPath, ctx: CGContext) {
        ctx.saveGState()
        UIColor.white.setStroke()
        path.lineWidth = outlineWidth
        path.lineJoinStyle = .round
        path.stroke()
        ctx.restoreGState()
    }

    private static func render(size: CGFloat, draw: (CGRect, CGContext) -> Void) -> UIImage {
        let pad = outlineWidth / 2 + 0.5
        let canvas = CGSize(width: size + pad * 2, height: size + pad * 2)
        return UIGraphicsImageRenderer(size: canvas).image { context in
            draw(CGRect(x: pad, y: pad, width: size, height: size), context.cgContext)
        }
    }
}

/// Chart-style waypoint symbol with the identifier tagged underneath.
final class WaypointAnnotationView: MKAnnotationView {
    static let reuseId = "waypoint"

    private let symbolView = UIImageView()
    private let label = MapTagLabel()

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
        let symbol = annotation.waypoint.symbol
        symbolView.image = WaypointSymbols.image(for: symbol)
        symbolView.sizeToFit()

        label.setTag(
            annotation.waypoint.identifier,
            font: .monospacedSystemFont(ofSize: symbol == .fix ? 10 : 11, weight: .semibold),
            color: WaypointSymbols.color(for: symbol)
        )

        MapLabelStyle.layoutSymbolAboveLabel(in: self, symbol: symbolView, label: label)
        // Navaids above airways and fixes; fixes yield to everything.
        displayPriority = symbol == .fix ? .defaultLow : .defaultHigh
        collisionMode = .rectangle
    }
}

/// Spreads waypoints evenly over the viewport instead of taking whatever a
/// LIMIT'ed index scan returns first — which, on the (lat, lon) index, is
/// the southernmost rows, leaving the top of a dense view empty.
///
/// The grid is anchored to absolute coordinates (not the box edges), so a
/// small pan keeps the same cells and the same picks: no flicker.
nonisolated enum WaypointThinning {
    static func spread(
        _ waypoints: [AeroDatabase.MapWaypoint],
        span: Double,
        maxCount: Int,
        gridDivisions: Int = 10
    ) -> [AeroDatabase.MapWaypoint] {
        guard waypoints.count > maxCount, span > 0 else { return waypoints }
        let cell = span / Double(gridDivisions)

        struct CellKey: Hashable { var row: Int; var col: Int }
        var cells: [CellKey: [AeroDatabase.MapWaypoint]] = [:]
        for waypoint in waypoints {
            let key = CellKey(
                row: Int((waypoint.latitude / cell).rounded(.down)),
                col: Int((waypoint.longitude / cell).rounded(.down))
            )
            cells[key, default: []].append(waypoint)
        }
        // Within a cell: navaids first, then a stable order.
        var queues = cells.values.map { members in
            members.sorted { a, b in
                let aNavaid = a.symbol != .fix, bNavaid = b.symbol != .fix
                if aNavaid != bNavaid { return aNavaid }
                return a.identifier < b.identifier
            }
        }
        queues.sort { ($0.first?.identifier ?? "") < ($1.first?.identifier ?? "") }

        // Round-robin one per cell until full.
        var result: [AeroDatabase.MapWaypoint] = []
        result.reserveCapacity(maxCount)
        var round = 0
        while result.count < maxCount {
            var tookAny = false
            for queue in queues where round < queue.count {
                result.append(queue[round])
                tookAny = true
                if result.count == maxCount { break }
            }
            if !tookAny { break }
            round += 1
        }
        return result
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

/// The airway's designator ("V306", "J87") tagged on the line. Without it
/// an airway is an anonymous stripe — the name is what a pilot needs.
final class AirwayLabelAnnotation: NSObject, MKAnnotation {
    let ident: String
    let isHigh: Bool
    @objc dynamic var coordinate: CLLocationCoordinate2D

    init(ident: String, isHigh: Bool, coordinate: CLLocationCoordinate2D) {
        self.ident = ident
        self.isHigh = isHigh
        self.coordinate = coordinate
    }
}

final class AirwayLabelAnnotationView: MKAnnotationView {
    static let reuseId = "airwayLabel"

    private let label = MapTagLabel()

    override var annotation: MKAnnotation? {
        didSet { configure() }
    }

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        addSubview(label)
        configure()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configure() {
        guard let annotation = annotation as? AirwayLabelAnnotation else { return }
        label.setTag(
            annotation.ident,
            font: .systemFont(ofSize: 10, weight: .bold),
            color: annotation.isHigh ? AeroPalette.airwayHigh : AeroPalette.airwayLow
        )
        label.frame.origin = .zero
        bounds = label.bounds
        centerOffset = .zero
        displayPriority = MKFeatureDisplayPriority(rawValue: 300)
        collisionMode = .rectangle
        isEnabled = false
    }
}

nonisolated enum AirwayLabelPlacement {
    /// Where to tag an airway: the midpoint of its on-screen segment nearest
    /// the viewport centre. The full line's midpoint is usually off screen
    /// (jet routes run coast to coast), so it can't be used.
    static func anchor(
        for coordinates: [Coordinate],
        minLat: Double, maxLat: Double, minLon: Double, maxLon: Double
    ) -> Coordinate? {
        let centerLat = (minLat + maxLat) / 2, centerLon = (minLon + maxLon) / 2
        var best: (point: Coordinate, distance: Double)?
        for (a, b) in zip(coordinates, coordinates.dropFirst()) {
            let mid = Coordinate(latitude: (a.latitude + b.latitude) / 2, longitude: (a.longitude + b.longitude) / 2)
            guard (minLat...maxLat).contains(mid.latitude), (minLon...maxLon).contains(mid.longitude) else { continue }
            let d = pow(mid.latitude - centerLat, 2) + pow(mid.longitude - centerLon, 2)
            if best == nil || d < best!.distance { best = (mid, d) }
        }
        return best?.point
    }
}

// MARK: Cased renderers

/// Strokes a white casing under the line before the normal draw, so the
/// overlay separates from chart ink of the same hue. Dashed styles get a
/// solid casing — a dashed line on a white track still reads as dashed.
///
/// Widths are scaled by `contentScaleFactor` to match how MapKit strokes
/// `lineWidth` itself; dividing by `zoomScale` alone lands the casing at the
/// line's own width and hides it.
nonisolated private func strokeCasing(path: CGPath?, lineWidth: CGFloat, casingWidth: CGFloat, zoomScale: MKZoomScale, contentScale: CGFloat, in context: CGContext) {
    guard let path, casingWidth > 0 else { return }
    context.saveGState()
    context.addPath(path)
    context.setStrokeColor(AeroPalette.casing.cgColor)
    context.setLineWidth((lineWidth + casingWidth * 2) * contentScale / zoomScale)
    context.setLineJoin(.round)
    context.setLineCap(.round)
    context.strokePath()
    context.restoreGState()
}

nonisolated final class CasedPolylineRenderer: MKPolylineRenderer {
    var casingWidth: CGFloat = 1.5

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        if path == nil { createPath() }
        strokeCasing(path: path, lineWidth: lineWidth, casingWidth: casingWidth, zoomScale: zoomScale, contentScale: contentScaleFactor, in: context)
        super.draw(mapRect, zoomScale: zoomScale, in: context)
    }
}

nonisolated final class CasedPolygonRenderer: MKPolygonRenderer {
    var casingWidth: CGFloat = 1.5

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        if path == nil { createPath() }
        strokeCasing(path: path, lineWidth: lineWidth, casingWidth: casingWidth, zoomScale: zoomScale, contentScale: contentScaleFactor, in: context)
        super.draw(mapRect, zoomScale: zoomScale, in: context)
    }
}

// MARK: Airspace

extension Airspace.Category {
    /// Conventional hues (blue B/D, magenta C, red SUA), pushed darker and
    /// more saturated than the sectional's own printing so the overlay
    /// stands off the chart instead of merging into it.
    var strokeColor: UIColor {
        switch self {
        case .classB: UIColor(red: 0.00, green: 0.27, blue: 0.78, alpha: 1)
        case .classC: UIColor(red: 0.72, green: 0.04, blue: 0.52, alpha: 1)
        case .classD: UIColor(red: 0.00, green: 0.36, blue: 0.86, alpha: 1)
        case .restricted, .prohibited: UIColor(red: 0.84, green: 0.10, blue: 0.10, alpha: 1)
        case .warning, .danger: UIColor(red: 0.88, green: 0.42, blue: 0.00, alpha: 1)
        }
    }

    /// Class D and SUA boundaries draw dashed, matching chart style.
    var isDashed: Bool {
        switch self {
        case .classD, .restricted, .warning, .danger: true
        case .classB, .classC, .prohibited: false
        }
    }

    /// B/C/D are outline-only: each shelf is its own polygon, so fills
    /// stacked into a grey wash over the busiest (most important) part of
    /// the chart. SUA keeps a tint — "am I inside it" is the question there.
    var fillAlpha: CGFloat {
        switch self {
        case .prohibited: 0.14
        case .restricted: 0.08
        case .warning, .danger: 0.05
        case .classB, .classC, .classD: 0
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
