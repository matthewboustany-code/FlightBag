import SwiftUI
import MapKit
import FBModels
import FBFlightPlan

// MARK: - Route waypoint annotations

/// A labeled point on the active route — the map shows every fix/navaid/
/// airport in the route, not just the course line. Procedures reuse it with
/// a blue tint.
final class RouteWaypointAnnotation: NSObject, MKAnnotation {
    let point: ActiveMapRoute.Point
    let tint: UIColor
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: point.coordinate.latitude, longitude: point.coordinate.longitude)
    }
    var title: String? { point.identifier }

    init(point: ActiveMapRoute.Point, tint: UIColor = .systemPink) {
        self.point = point
        self.tint = tint
    }
}

/// Magenta route-point marker (EFB convention: the course line's color),
/// always displayed — route points outrank everything except ownship.
final class RouteWaypointAnnotationView: MKAnnotationView {
    static let reuseId = "routeWaypoint"

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
        guard let annotation = annotation as? RouteWaypointAnnotation else { return }
        let isAirport = annotation.point.kind == "airport"
        let config = UIImage.SymbolConfiguration(pointSize: isAirport ? 15 : 12, weight: .bold)
        symbolView.image = UIImage(
            systemName: isAirport ? "circle.circle.fill" : "diamond.fill",
            withConfiguration: config
        )?.withTintColor(annotation.tint, renderingMode: .alwaysOriginal)
        symbolView.sizeToFit()

        label.attributedText = MapLabelStyle.halo(
            annotation.point.identifier,
            font: .systemFont(ofSize: 13, weight: .bold),
            color: annotation.tint
        )
        label.sizeToFit()

        MapLabelStyle.layoutSymbolAboveLabel(in: self, symbol: symbolView, label: label)
        displayPriority = .required
        zPriority = MKAnnotationViewZPriority(rawValue: MKAnnotationViewZPriority.max.rawValue - 1)
        collisionMode = .rectangle
    }
}

/// Tag subclass so `rendererFor` can style SID/STAR branches (dashed blue)
/// distinctly from the planned route.
final class ProcedurePolyline: MKPolyline {}

// MARK: - Editor panel

/// Floating card listing the active route's points with delete, reorder,
/// and add — edits write straight back to `AppEnvironment.activeMapRoute`,
/// which the map re-syncs from. Non-modal like MapInfoPanel: the map stays
/// live around it.
struct RouteEditorPanel: View {
    let onClose: () -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var newIdentifier = ""
    @State private var addError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            if let route = environment.activeMapRoute {
                pointsList(route)
                addRow
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }

    private var header: some View {
        HStack {
            Text(environment.activeMapRoute?.label ?? "Route")
                .font(.headline)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("map.routeEditor.close")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func pointsList(_ route: ActiveMapRoute) -> some View {
        List {
            ForEach(route.points) { point in
                HStack(spacing: 10) {
                    Image(systemName: symbolName(point))
                        .foregroundStyle(.pink)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(point.identifier)
                            .font(.callout.weight(.semibold).monospaced())
                        if let airway = point.airway {
                            Text("via \(airway)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
            }
            .onDelete { offsets in
                environment.activeMapRoute?.points.remove(atOffsets: offsets)
                if environment.activeMapRoute?.points.isEmpty == true {
                    environment.activeMapRoute = nil
                    onClose()
                }
            }
            .onMove { source, destination in
                environment.activeMapRoute?.points.move(fromOffsets: source, toOffset: destination)
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // Always-on edit mode: reorder handles and delete affordances are
        // the point of this panel.
        .environment(\.editMode, .constant(.active))
    }

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField("Add waypoint (e.g. CWK)", text: $newIdentifier)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .onSubmit(add)
                    .accessibilityIdentifier("map.routeEditor.addField")
                Button("Add", action: add)
                    .buttonStyle(.borderedProminent)
                    .disabled(newIdentifier.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let addError {
                Text(addError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
    }

    private func symbolName(_ point: ActiveMapRoute.Point) -> String {
        switch point.kind {
        case "airport": "circle.circle.fill"
        case "navaid": "hexagon.fill"
        default: "diamond.fill"
        }
    }

    private func add() {
        let identifier = newIdentifier.trimmingCharacters(in: .whitespaces).uppercased()
        guard !identifier.isEmpty else { return }
        guard let db = environment.aeroDatabase else { return }
        Task {
            guard let waypoint = try? await db.resolveWaypoint(identifier: identifier) else {
                addError = "\(identifier) not found"
                return
            }
            environment.activeMapRoute?.points.append(ActiveMapRoute.Point(
                identifier: waypoint.identifier,
                coordinate: waypoint.coordinate,
                kind: waypoint.kind.rawValue,
                airway: nil
            ))
            newIdentifier = ""
            addError = nil
        }
    }
}
