import SwiftUI
import MapKit

/// The EFB map: MKMapView with stacked raster overlays (sectional under
/// radar), airport annotations from the offline database, and ownship.
/// All map behavior stays behind this representable so the map engine can
/// be swapped without touching feature code.
struct EFBMapView: UIViewRepresentable {
    let layers: MapLayersState
    let position: OwnshipPosition?
    @Binding var followOwnship: Bool
    @Binding var trackUp: Bool
    var onSelectAirport: (String) -> Void

    @Environment(AppEnvironment.self) private var environment

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.mapType = .mutedStandard
        map.showsCompass = true
        map.pointOfInterestFilter = .excludingAll
        map.isPitchEnabled = false
        map.setRegion(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 30.19, longitude: -97.67),
                span: MKCoordinateSpan(latitudeDelta: 2.2, longitudeDelta: 2.2)
            ),
            animated: false
        )
        map.register(AirportAnnotationView.self, forAnnotationViewWithReuseIdentifier: AirportAnnotationView.reuseId)
        map.register(OwnshipAnnotationView.self, forAnnotationViewWithReuseIdentifier: OwnshipAnnotationView.reuseId)
        context.coordinator.map = map
        context.coordinator.aeroDatabase = environment.aeroDatabase
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelectAirport = onSelectAirport
        coordinator.airportsEnabled = layers.airportsEnabled
        coordinator.syncOverlays(on: map, layers: layers)
        coordinator.syncOwnship(on: map, position: position, followOwnship: followOwnship, trackUp: trackUp)
        if !layers.airportsEnabled {
            coordinator.clearAirportAnnotations(on: map)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        weak var map: MKMapView?
        var aeroDatabase: AeroDatabase?
        var onSelectAirport: (String) -> Void = { _ in }
        var airportsEnabled = true

        private var sectionalOverlays: [URL: MBTilesOverlay] = [:]
        private var radarOverlay: MKTileOverlay?
        private var overlayAlphas: [ObjectIdentifier: CGFloat] = [:]
        private let ownshipAnnotation = OwnshipAnnotation()
        private var ownshipOnMap = false
        private var airportAnnotations: [String: AirportAnnotation] = [:]
        private var annotationTask: Task<Void, Never>?

        // MARK: Overlay stack

        func syncOverlays(on map: MKMapView, layers: MapLayersState) {
            // Sectionals (bottom of the aviation stack).
            for chart in layers.availableCharts {
                if layers.sectionalEnabled, sectionalOverlays[chart.url] == nil,
                   let overlay = MBTilesOverlay(fileURL: chart.url) {
                    sectionalOverlays[chart.url] = overlay
                    map.insertOverlay(overlay, at: 0, level: .aboveRoads)
                }
            }
            if !layers.sectionalEnabled {
                for (_, overlay) in sectionalOverlays { map.removeOverlay(overlay) }
                sectionalOverlays.removeAll()
            }
            for overlay in sectionalOverlays.values {
                setAlpha(CGFloat(layers.sectionalOpacity), for: overlay, on: map)
            }

            // Radar (above charts).
            if layers.radarEnabled, radarOverlay == nil {
                let radar = MKTileOverlay(urlTemplate: "https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/nexrad-n0q-900913/{z}/{x}/{y}.png")
                radar.canReplaceMapContent = false
                radar.maximumZ = 16
                radarOverlay = radar
                map.addOverlay(radar, level: .aboveLabels)
            }
            if !layers.radarEnabled, let radar = radarOverlay {
                map.removeOverlay(radar)
                radarOverlay = nil
            }
            if let radar = radarOverlay {
                setAlpha(CGFloat(layers.radarOpacity), for: radar, on: map)
            }
        }

        private func setAlpha(_ alpha: CGFloat, for overlay: MKOverlay, on map: MKMapView) {
            overlayAlphas[ObjectIdentifier(overlay)] = alpha
            if let renderer = map.renderer(for: overlay) as? MKTileOverlayRenderer {
                renderer.alpha = alpha
            }
        }

        nonisolated func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let tileOverlay = overlay as? MKTileOverlay else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKTileOverlayRenderer(tileOverlay: tileOverlay)
            MainActor.assumeIsolated {
                renderer.alpha = overlayAlphas[ObjectIdentifier(overlay)] ?? 1.0
            }
            return renderer
        }

        // MARK: Ownship

        func syncOwnship(on map: MKMapView, position: OwnshipPosition?, followOwnship: Bool, trackUp: Bool) {
            guard let position else { return }
            ownshipAnnotation.coordinate = position.coordinate
            ownshipAnnotation.trackDegrees = position.trackDegrees
            if !ownshipOnMap {
                map.addAnnotation(ownshipAnnotation)
                ownshipOnMap = true
            }
            (map.view(for: ownshipAnnotation) as? OwnshipAnnotationView)?.updateRotation(map: map)

            if followOwnship {
                let camera = MKMapCamera(
                    lookingAtCenter: position.coordinate,
                    fromDistance: map.camera.centerCoordinateDistance,
                    pitch: 0,
                    heading: trackUp ? (position.trackDegrees ?? 0) : 0
                )
                map.setCamera(camera, animated: true)
            }
        }

        // MARK: Airport annotations

        nonisolated func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            MainActor.assumeIsolated { refreshAirportAnnotations(on: mapView) }
        }

        func clearAirportAnnotations(on map: MKMapView) {
            map.removeAnnotations(Array(airportAnnotations.values))
            airportAnnotations.removeAll()
        }

        private func refreshAirportAnnotations(on map: MKMapView) {
            guard airportsEnabled, let db = aeroDatabase else { return }
            let region = map.region
            // Only at usable zoom; a whole-CONUS view would fetch thousands.
            guard region.span.latitudeDelta < 3.5 else {
                clearAirportAnnotations(on: map)
                return
            }
            annotationTask?.cancel()
            annotationTask = Task { [weak self, weak map] in
                guard let results = try? await db.airportsNear(
                    latitude: region.center.latitude,
                    longitude: region.center.longitude,
                    spanDegrees: max(region.span.latitudeDelta, region.span.longitudeDelta) / 2 + 0.1,
                    limit: 80
                ), let self, let map, !Task.isCancelled else { return }

                var keep = Set<String>()
                for result in results {
                    guard let lat = result.latitude, let lon = result.longitude else { continue }
                    keep.insert(result.id)
                    if self.airportAnnotations[result.id] == nil {
                        let annotation = AirportAnnotation(
                            airportId: result.displayIdentifier,
                            title: result.displayIdentifier,
                            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)
                        )
                        self.airportAnnotations[result.id] = annotation
                        map.addAnnotation(annotation)
                    }
                }
                let stale = self.airportAnnotations.filter { !keep.contains($0.key) }
                map.removeAnnotations(Array(stale.values))
                for key in stale.keys { self.airportAnnotations[key] = nil }
            }
        }

        nonisolated func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            MainActor.assumeIsolated {
                if annotation is OwnshipAnnotation {
                    return mapView.dequeueReusableAnnotationView(withIdentifier: OwnshipAnnotationView.reuseId, for: annotation)
                }
                if annotation is AirportAnnotation {
                    return mapView.dequeueReusableAnnotationView(withIdentifier: AirportAnnotationView.reuseId, for: annotation)
                }
                return nil
            }
        }

        nonisolated func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            MainActor.assumeIsolated {
                guard let annotation = view.annotation as? AirportAnnotation else { return }
                mapView.deselectAnnotation(annotation, animated: false)
                onSelectAirport(annotation.airportId)
            }
        }
    }
}

// MARK: Annotations

final class AirportAnnotation: NSObject, MKAnnotation {
    let airportId: String
    let title: String?
    let coordinate: CLLocationCoordinate2D

    init(airportId: String, title: String, coordinate: CLLocationCoordinate2D) {
        self.airportId = airportId
        self.title = title
        self.coordinate = coordinate
    }
}

final class AirportAnnotationView: MKAnnotationView {
    static let reuseId = "airport"

    override var annotation: MKAnnotation? {
        didSet { configure() }
    }

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        configure()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configure() {
        let config = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        image = UIImage(systemName: "circle.circle", withConfiguration: config)?
            .withTintColor(.systemIndigo, renderingMode: .alwaysOriginal)
        canShowCallout = false
        displayPriority = .defaultLow
        collisionMode = .circle
    }
}

final class OwnshipAnnotation: NSObject, MKAnnotation {
    dynamic var coordinate = CLLocationCoordinate2D()
    var trackDegrees: Double?
}

final class OwnshipAnnotationView: MKAnnotationView {
    static let reuseId = "ownship"

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        let config = UIImage.SymbolConfiguration(pointSize: 26, weight: .bold)
        image = UIImage(systemName: "location.north.fill", withConfiguration: config)?
            .withTintColor(.systemCyan, renderingMode: .alwaysOriginal)
        displayPriority = .required
        zPriority = .max
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Rotate the ownship arrow to its ground track relative to the camera.
    func updateRotation(map: MKMapView) {
        guard let annotation = annotation as? OwnshipAnnotation else { return }
        let track = annotation.trackDegrees ?? 0
        let relative = (track - map.camera.heading) * .pi / 180
        transform = CGAffineTransform(rotationAngle: relative)
    }
}
