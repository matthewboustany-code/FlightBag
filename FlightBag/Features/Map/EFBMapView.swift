import SwiftUI
import MapKit
import FBModels

/// The EFB map: MKMapView with stacked raster overlays (sectional under
/// radar), airport annotations from the offline database, and ownship.
/// All map behavior stays behind this representable so the map engine can
/// be swapped without touching feature code.
struct EFBMapView: UIViewRepresentable {
    let layers: MapLayersState
    let position: OwnshipPosition?
    /// Observed so membership changes re-run updateUIView; the store is
    /// read from the environment.
    var trafficVersion: Int = 0
    /// Same, for the FIS-B mosaic.
    var fisbRadarVersion: Int = 0
    var route: ActiveMapRoute?
    var procedure: ActiveMapProcedure?
    var activePlate: PlateMetadata?
    @Binding var followOwnship: Bool
    @Binding var trackUp: Bool
    var onSelectAirport: (String) -> Void
    var onInspectAdvisories: ([AdvisoryDisplayInfo]) -> Void = { _ in }

    @Environment(AppEnvironment.self) private var environment

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.mapType = .mutedStandard
        map.showsCompass = true
        map.pointOfInterestFilter = .excludingAll
        map.isPitchEnabled = false
        // `-mapDemoSpan 24` adjusts the initial view for screenshot
        // automation (wide spans recenter on the whole US).
        let demoSpan = UserDefaults.standard.double(forKey: "mapDemoSpan")
        let span = demoSpan > 0 ? demoSpan : 2.2
        map.setRegion(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: demoSpan > 10 ? 38.5 : 30.19, longitude: demoSpan > 10 ? -96 : -97.67),
                span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)
            ),
            animated: false
        )
        map.register(AirportAnnotationView.self, forAnnotationViewWithReuseIdentifier: AirportAnnotationView.reuseId)
        map.register(OwnshipAnnotationView.self, forAnnotationViewWithReuseIdentifier: OwnshipAnnotationView.reuseId)
        map.register(WaypointAnnotationView.self, forAnnotationViewWithReuseIdentifier: WaypointAnnotationView.reuseId)
        map.register(RouteWaypointAnnotationView.self, forAnnotationViewWithReuseIdentifier: RouteWaypointAnnotationView.reuseId)
        map.register(TrafficAnnotationView.self, forAnnotationViewWithReuseIdentifier: TrafficAnnotationView.reuseId)
        context.coordinator.map = map
        context.coordinator.aeroDatabase = environment.aeroDatabase
        context.coordinator.airspaceStore = environment.airspaceStore
        context.coordinator.plateStore = environment.plateStore

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        map.addGestureRecognizer(tap)

        // Two-finger hold = measuring ruler (pinch wins if the fingers move
        // right away).
        let ruler = TwoFingerHoldGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleRuler(_:)))
        ruler.cancelsTouchesInView = false
        ruler.delegate = context.coordinator
        map.addGestureRecognizer(ruler)

        let hud = RulerHUDView(frame: map.bounds)
        hud.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        map.addSubview(hud)
        context.coordinator.rulerHUD = hud

        // `-mapDemoRuler YES`: show the ruler at fixed screen points, since
        // screenshot automation can't synthesize two-finger touches.
        if UserDefaults.standard.bool(forKey: "mapDemoRuler") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak map, weak hud] in
                guard let map, let hud else { return }
                hud.update(
                    from: CGPoint(x: map.bounds.width * 0.3, y: map.bounds.height * 0.62),
                    to: CGPoint(x: map.bounds.width * 0.72, y: map.bounds.height * 0.35),
                    on: map
                )
            }
        }
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelectAirport = onSelectAirport
        coordinator.onInspectAdvisories = onInspectAdvisories
        coordinator.airportsEnabled = layers.airportsEnabled
        coordinator.layersState = layers
        coordinator.syncOverlays(on: map, layers: layers)
        coordinator.syncFISBRadar(on: map, store: environment.fisbRadarStore, layers: layers)
        coordinator.syncAdvisories(on: map, layers: layers, store: environment.advisoryStore)
        coordinator.refreshAeronautical(on: map)
        coordinator.syncRoute(on: map, route: route)
        coordinator.syncProcedure(on: map, procedure: procedure)
        coordinator.onPlateUnavailable = { [environment] in environment.activePlateOverlay = nil }
        coordinator.syncPlateOverlay(on: map, plate: activePlate, layers: layers)
        coordinator.syncOwnship(on: map, position: position, followOwnship: followOwnship, trackUp: trackUp)
        coordinator.syncTraffic(
            on: map,
            store: environment.trafficStore,
            enabled: layers.trafficEnabled,
            ownshipAltitudeFt: position?.altitudeFeet.map(Int.init)
        )
        if !layers.airportsEnabled {
            coordinator.clearAirportAnnotations(on: map)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        weak var map: MKMapView?
        var aeroDatabase: AeroDatabase?
        var airspaceStore: AirspaceStore?
        var plateStore: PlateStore?
        var layersState: MapLayersState?
        var onSelectAirport: (String) -> Void = { _ in }
        var onInspectAdvisories: ([AdvisoryDisplayInfo]) -> Void = { _ in }
        var onPlateUnavailable: () -> Void = {}
        var airportsEnabled = true

        private var chartOverlays: [MKTileOverlay] = []
        private var chartKey: String?
        private var radarOverlay: MKTileOverlay?
        private var basemapOverlays: [MBTilesOverlay] = []
        private var basemapKey: String?
        private var fisbRadarOverlay: FISBRadarOverlay?
        private var fisbRadarKey: Int?
        private var advisoryOverlays: [AdvisoryPolygon] = []
        private var advisoryKey: String?
        private var waypointAnnotations: [WaypointAnnotation] = []
        private var airwayPolylines: [AirwayPolyline] = []
        private var airspaceOverlays: [AdvisoryPolygon] = []
        private var aeroKey: String?
        private var aeroTask: Task<Void, Never>?
        private var routePolyline: MKPolyline?
        private var routeKey: ActiveMapRoute?
        private var routeAnnotations: [RouteWaypointAnnotation] = []
        private var procedurePolylines: [ProcedurePolyline] = []
        private var procedureAnnotations: [RouteWaypointAnnotation] = []
        private var procedureKey: ActiveMapProcedure?
        private var plateOverlay: PlateOverlay?
        private var plateKey: String?
        private var plateTask: Task<Void, Never>?
        private var overlayAlphas: [ObjectIdentifier: CGFloat] = [:]
        private let ownshipAnnotation = OwnshipAnnotation()
        private var ownshipOnMap = false
        private var airportAnnotations: [String: AirportAnnotation] = [:]
        private var annotationTask: Task<Void, Never>?
        private var trafficAnnotations: [UInt32: TrafficAnnotation] = [:]
        private var trafficMembershipVersion = -1

        // MARK: Overlay stack

        func syncOverlays(on map: MKMapView, layers: MapLayersState) {
            // Offline basemap (bottom of everything): shaded-relief MBTiles
            // that keep the map usable with no connectivity.
            let basemapSets = layers.basemapEnabled ? layers.availableBasemaps : []
            let newBasemapKey = basemapSets.map(\.id).joined(separator: ",")
            if newBasemapKey != basemapKey {
                basemapKey = newBasemapKey
                for overlay in basemapOverlays { map.removeOverlay(overlay) }
                basemapOverlays = basemapSets.compactMap { MBTilesOverlay(fileURL: $0.url) }
                for overlay in basemapOverlays {
                    map.insertOverlay(overlay, at: 0, level: .aboveRoads)
                }
                // Charts must sit above the rebuilt basemap; force a rebuild.
                chartKey = nil
            }

            // Aeronautical chart: offline MBTiles when downloaded, FAA
            // streaming tiles otherwise.
            let offlineSets = layers.offlineSetsForSelectedChart
            let key = (layers.chart?.rawValue ?? "none") + "|" + offlineSets.map(\.id).joined(separator: ",")
            if key != chartKey {
                chartKey = key
                for overlay in chartOverlays { map.removeOverlay(overlay) }
                chartOverlays.removeAll()

                if let chart = layers.chart {
                    if offlineSets.isEmpty {
                        chartOverlays.append(StreamingChartOverlay(kind: chart))
                    } else {
                        for set in offlineSets {
                            if let overlay = MBTilesOverlay(fileURL: set.url) {
                                chartOverlays.append(overlay)
                            }
                        }
                    }
                    // Above every basemap overlay, below radar/advisories.
                    for overlay in chartOverlays {
                        map.insertOverlay(overlay, at: basemapOverlays.count, level: .aboveRoads)
                    }
                }
            }
            for overlay in chartOverlays {
                setAlpha(CGFloat(layers.chartOpacity), for: overlay, on: map)
            }

            // Radar (above charts): internet tiles or the FIS-B mosaic.
            let wantsInternetRadar = layers.radarEnabled && layers.radarSource == .internet
            if wantsInternetRadar, radarOverlay == nil {
                let radar = MKTileOverlay(urlTemplate: "https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/nexrad-n0q-900913/{z}/{x}/{y}.png")
                radar.canReplaceMapContent = false
                radar.maximumZ = 16
                radarOverlay = radar
                map.addOverlay(radar, level: .aboveLabels)
            }
            if !wantsInternetRadar, let radar = radarOverlay {
                map.removeOverlay(radar)
                radarOverlay = nil
            }
            if let radar = radarOverlay {
                setAlpha(CGFloat(layers.radarOpacity), for: radar, on: map)
            }
        }

        // MARK: FIS-B radar

        func syncFISBRadar(on map: MKMapView, store: FISBRadarStore, layers: MapLayersState) {
            let enabled = layers.radarEnabled && layers.radarSource == .adsb
            guard enabled else {
                if let overlay = fisbRadarOverlay {
                    map.removeOverlay(overlay)
                    fisbRadarOverlay = nil
                    fisbRadarKey = nil
                }
                return
            }

            let overlay: FISBRadarOverlay
            if let existing = fisbRadarOverlay {
                overlay = existing
            } else {
                overlay = FISBRadarOverlay()
                fisbRadarOverlay = overlay
                fisbRadarKey = nil
                map.addOverlay(overlay, level: .aboveLabels)
            }
            setAlpha(CGFloat(layers.radarOpacity), for: overlay, on: map)

            // Swap the snapshot and repaint only when the mosaic changed.
            guard fisbRadarKey != store.dataVersion else { return }
            fisbRadarKey = store.dataVersion
            overlay.mosaic = store.mosaic
            (map.renderer(for: overlay) as? FISBRadarRenderer)?.setNeedsDisplay()
        }

        // MARK: Aeronautical vector layer

        /// Waypoints, airways, and airspace for the current viewport,
        /// re-queried when the region or toggles change. Density is gated by
        /// zoom so a whole-country view never tries to draw 70k fixes.
        func refreshAeronautical(on map: MKMapView) {
            guard let layers = layersState else { return }
            let region = map.region
            let key = String(
                format: "%.2f,%.2f,%.2f|%@%@%@|%@",
                region.center.latitude, region.center.longitude, region.span.latitudeDelta,
                layers.waypointsEnabled ? "1" : "0",
                layers.airwaysLowEnabled ? "1" : "0",
                layers.airwaysHighEnabled ? "1" : "0",
                layers.enabledAirspaceCategories.map(\.rawValue).sorted().joined()
            )
            guard key != aeroKey else { return }
            aeroKey = key

            let span = max(region.span.latitudeDelta, region.span.longitudeDelta)
            let box = (
                minLat: region.center.latitude - region.span.latitudeDelta / 2,
                maxLat: region.center.latitude + region.span.latitudeDelta / 2,
                minLon: region.center.longitude - region.span.longitudeDelta / 2,
                maxLon: region.center.longitude + region.span.longitudeDelta / 2
            )

            aeroTask?.cancel()
            aeroTask = Task { [weak self, weak map] in
                // Debounce: pans/zooms retrigger rapidly, and the airspace
                // service is rate-limited — only the settled region fetches.
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, let self, let map, let layers = self.layersState else { return }
                let db = self.aeroDatabase

                var waypoints: [AeroDatabase.MapWaypoint] = []
                if layers.waypointsEnabled, span < 5, let db {
                    waypoints += (try? await db.navaidsIn(minLat: box.minLat, maxLat: box.maxLat, minLon: box.minLon, maxLon: box.maxLon)) ?? []
                    if span < 1.6 {
                        waypoints += (try? await db.fixesIn(minLat: box.minLat, maxLat: box.maxLat, minLon: box.minLon, maxLon: box.maxLon)) ?? []
                    }
                }

                var airways: [AeroDatabase.AirwayLine] = []
                if (layers.airwaysLowEnabled || layers.airwaysHighEnabled), span < 6, let db {
                    let all = (try? await db.airwaysIn(minLat: box.minLat, maxLat: box.maxLat, minLon: box.minLon, maxLon: box.maxLon)) ?? []
                    airways = all.filter { $0.isHigh ? layers.airwaysHighEnabled : layers.airwaysLowEnabled }
                }

                // nil = fetch failed: keep the previous boundaries on screen.
                var airspaces: [Airspace]? = []
                if !layers.enabledAirspaceCategories.isEmpty, span < 8, let store = self.airspaceStore {
                    airspaces = await store.airspaces(
                        categories: layers.enabledAirspaceCategories,
                        minLat: box.minLat, maxLat: box.maxLat, minLon: box.minLon, maxLon: box.maxLon
                    )
                }

                guard !Task.isCancelled else { return }
                self.apply(waypoints: waypoints, airways: airways, airspaces: airspaces, on: map)
            }
        }

        private func apply(waypoints: [AeroDatabase.MapWaypoint], airways: [AeroDatabase.AirwayLine], airspaces: [Airspace]?, on map: MKMapView) {
            map.removeAnnotations(waypointAnnotations)
            waypointAnnotations = waypoints.map(WaypointAnnotation.init)
            map.addAnnotations(waypointAnnotations)

            map.removeOverlays(airwayPolylines)
            airwayPolylines = airways.map(AirwayPolyline.make)
            map.addOverlays(airwayPolylines, level: .aboveLabels)

            if let airspaces {
                map.removeOverlays(airspaceOverlays)
                airspaceOverlays = airspaces.flatMap { airspace in
                    airspace.polygons.map { AdvisoryPolygon.makeAirspace(ring: $0, airspace: airspace) }
                }
                map.addOverlays(airspaceOverlays, level: .aboveLabels)
            }
        }

        // MARK: Advisories

        func syncAdvisories(on map: MKMapView, layers: MapLayersState, store: AdvisoryStore) {
            let key = [
                layers.tfrsEnabled, layers.sigmetsEnabled, layers.airmetSierraEnabled,
                layers.airmetTangoEnabled, layers.airmetZuluEnabled,
            ].map { $0 ? "1" : "0" }.joined()
                + "|\(store.dataVersion)"
                + "|\(layers.advisoryAltitudeFilterEnabled ? Int(layers.advisoryFilterAltitudeFt) : -1)"
            guard key != advisoryKey else { return }
            advisoryKey = key

            map.removeOverlays(advisoryOverlays)
            advisoryOverlays = AdvisoryOverlayBuilder.overlays(layers: layers, store: store)
            map.addOverlays(advisoryOverlays, level: .aboveLabels)
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let map else { return }
            let tappable = advisoryOverlays + airspaceOverlays
            guard !tappable.isEmpty else { return }
            let point = gesture.location(in: map)
            // Let annotation taps win (they present the airport sheet).
            if map.hitTest(point, with: nil) is MKAnnotationView { return }

            let mapPoint = MKMapPoint(map.convert(point, toCoordinateFrom: map))
            let hits = tappable.compactMap { overlay -> AdvisoryDisplayInfo? in
                guard overlay.boundingMapRect.contains(mapPoint),
                      let renderer = map.renderer(for: overlay) as? MKPolygonRenderer,
                      let path = renderer.path,
                      path.contains(renderer.point(for: mapPoint)) else { return nil }
                return overlay.info
            }
            if !hits.isEmpty {
                onInspectAdvisories(hits)
            }
        }

        nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        // MARK: Ruler

        var rulerHUD: RulerHUDView?

        @objc func handleRuler(_ gesture: TwoFingerHoldGestureRecognizer) {
            guard let map, let hud = rulerHUD else { return }
            switch gesture.state {
            case .began, .changed:
                let points = gesture.touchPoints
                guard points.count == 2 else { return }
                if gesture.state == .began {
                    // The fingers now belong to the ruler, not the camera.
                    map.isZoomEnabled = false
                    map.isRotateEnabled = false
                }
                hud.update(from: points[0], to: points[1], on: map)
            default:
                map.isZoomEnabled = true
                map.isRotateEnabled = true
                hud.hide()
            }
        }

        // MARK: Route

        func syncRoute(on map: MKMapView, route: ActiveMapRoute?) {
            guard route != routeKey else { return }
            // Re-zoom only when a route arrives or is replaced, not on every
            // editor tweak.
            let shouldZoom = routeKey == nil || route?.label != routeKey?.label
            routeKey = route
            if let existing = routePolyline {
                map.removeOverlay(existing)
                routePolyline = nil
            }
            map.removeAnnotations(routeAnnotations)
            routeAnnotations.removeAll()

            guard let route, route.points.count >= 2 else { return }
            let points = route.coordinates.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            }
            let polyline = MKPolyline(coordinates: points, count: points.count)
            routePolyline = polyline
            map.addOverlay(polyline, level: .aboveLabels)

            routeAnnotations = route.points.map { RouteWaypointAnnotation(point: $0) }
            map.addAnnotations(routeAnnotations)

            if shouldZoom {
                map.setVisibleMapRect(
                    polyline.boundingMapRect,
                    edgePadding: UIEdgeInsets(top: 60, left: 60, bottom: 60, right: 60),
                    animated: true
                )
            }
        }

        // MARK: Procedure (SID/STAR) overlay

        /// Vector branches of the active procedure — one dashed polyline per
        /// transition plus labeled fixes. Same delta pattern as syncRoute.
        func syncProcedure(on map: MKMapView, procedure: ActiveMapProcedure?) {
            guard procedure != procedureKey else { return }
            let shouldZoom = procedureKey == nil || procedure?.label != procedureKey?.label
            procedureKey = procedure
            for polyline in procedurePolylines { map.removeOverlay(polyline) }
            procedurePolylines.removeAll()
            map.removeAnnotations(procedureAnnotations)
            procedureAnnotations.removeAll()

            guard let procedure else { return }
            for branch in procedure.branches {
                let coordinates = branch.points.map {
                    CLLocationCoordinate2D(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
                }
                let polyline = ProcedurePolyline(coordinates: coordinates, count: coordinates.count)
                procedurePolylines.append(polyline)
                map.addOverlay(polyline, level: .aboveLabels)
            }
            procedureAnnotations = procedure.uniquePoints.map {
                RouteWaypointAnnotation(point: $0, tint: .systemBlue)
            }
            map.addAnnotations(procedureAnnotations)

            if shouldZoom, let union = procedurePolylines.map(\.boundingMapRect).reduce(nil, { (partial: MKMapRect?, rect) in
                partial.map { $0.union(rect) } ?? rect
            }) {
                map.setVisibleMapRect(
                    union,
                    edgePadding: UIEdgeInsets(top: 60, left: 60, bottom: 60, right: 60),
                    animated: true
                )
            }
        }

        // MARK: Plate overlay

        /// Pins/unpins the active approach plate. Fetch (PlateStore caches),
        /// georef parse, and rasterization all happen off the main actor;
        /// failures (non-georeferenced chart, evicted cycle while offline)
        /// clear the request via `onPlateUnavailable`.
        func syncPlateOverlay(on map: MKMapView, plate: PlateMetadata?, layers: MapLayersState) {
            if plate?.id != plateKey {
                plateKey = plate?.id
                plateTask?.cancel()
                if let existing = plateOverlay {
                    map.removeOverlay(existing)
                    plateOverlay = nil
                }
                guard let plate, let store = plateStore else {
                    if plate != nil { onPlateUnavailable() }
                    return
                }
                let database = aeroDatabase
                plateTask = Task { [weak self, weak map] in
                    var built: PlateOverlayImage?
                    if let url = try? await store.fetch(plate) {
                        // Resolver covers embedded (IAP) and runway-matched
                        // (airport diagram) georeferencing, cached.
                        if let georef = await PlateGeoreferenceResolver.resolve(plate: plate, url: url, database: database) {
                            built = await Task.detached(priority: .userInitiated) {
                                guard let image = PlateRasterizer.rasterize(url: url, georeference: georef) else { return nil }
                                return PlateOverlayImage(image: image, corners: georef.corners)
                            }.value
                        }
                    }
                    guard let self, let map, !Task.isCancelled, self.plateKey == plate.id else { return }
                    guard let built else {
                        self.plateKey = nil
                        self.onPlateUnavailable()
                        return
                    }
                    let overlay = PlateOverlay(image: built.image, corners: built.corners, plateId: plate.id)
                    self.plateOverlay = overlay
                    map.addOverlay(overlay, level: .aboveLabels)
                    self.setAlpha(CGFloat(layers.plateOpacity), for: overlay, on: map)
                    map.setVisibleMapRect(
                        overlay.boundingMapRect,
                        edgePadding: UIEdgeInsets(top: 40, left: 40, bottom: 40, right: 40),
                        animated: true
                    )
                }
            }
            if let overlay = plateOverlay {
                setAlpha(CGFloat(layers.plateOpacity), for: overlay, on: map)
            }
        }

        private func setAlpha(_ alpha: CGFloat, for overlay: MKOverlay, on map: MKMapView) {
            overlayAlphas[ObjectIdentifier(overlay)] = alpha
            switch map.renderer(for: overlay) {
            case let renderer as MKTileOverlayRenderer:
                renderer.alpha = alpha
            case let renderer as FISBRadarRenderer:
                if renderer.alpha != alpha {
                    renderer.alpha = alpha
                    renderer.setNeedsDisplay()
                }
            case let renderer as PlateOverlayRenderer:
                if renderer.alpha != alpha {
                    renderer.alpha = alpha
                    renderer.setNeedsDisplay()
                }
            default:
                break
            }
        }

        nonisolated func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let radar = overlay as? FISBRadarOverlay {
                let renderer = FISBRadarRenderer(overlay: radar)
                MainActor.assumeIsolated {
                    renderer.alpha = overlayAlphas[ObjectIdentifier(overlay)] ?? 1.0
                }
                return renderer
            }
            if let plate = overlay as? PlateOverlay {
                let renderer = PlateOverlayRenderer(overlay: plate)
                MainActor.assumeIsolated {
                    renderer.alpha = overlayAlphas[ObjectIdentifier(overlay)] ?? 1.0
                }
                return renderer
            }
            if let advisory = overlay as? AdvisoryPolygon {
                let renderer = MKPolygonRenderer(polygon: advisory)
                let (stroke, fillAlpha, dashed) = MainActor.assumeIsolated {
                    (advisory.strokeColor, advisory.fillAlpha, advisory.isDashed)
                }
                renderer.strokeColor = stroke
                renderer.fillColor = stroke.withAlphaComponent(fillAlpha)
                renderer.lineWidth = 2
                if dashed {
                    renderer.lineDashPattern = [6, 5]
                }
                return renderer
            }
            if let airway = overlay as? AirwayPolyline {
                let renderer = MKPolylineRenderer(polyline: airway)
                let isHigh = MainActor.assumeIsolated { airway.isHigh }
                renderer.strokeColor = isHigh
                    ? UIColor.systemGray.withAlphaComponent(0.8)
                    : UIColor.systemBlue.withAlphaComponent(0.55)
                renderer.lineWidth = 1.5
                return renderer
            }
            if let procedure = overlay as? ProcedurePolyline {
                // Dashed blue: a procedure preview, distinct from the
                // magenta planned-route line.
                let renderer = MKPolylineRenderer(polyline: procedure)
                renderer.strokeColor = .systemBlue
                renderer.lineWidth = 3
                renderer.lineDashPattern = [6, 6]
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            if let polyline = overlay as? MKPolyline {
                // EFB convention: the planned course line is magenta.
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = .systemPink
                renderer.lineWidth = 4
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
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

        // MARK: Traffic

        /// Mutates existing traffic annotations in place and adds/removes
        /// only on membership change — the airport delta pattern, tuned for
        /// the 1 Hz update rate.
        func syncTraffic(on map: MKMapView, store: TrafficStore, enabled: Bool, ownshipAltitudeFt: Int?) {
            guard enabled else {
                if !trafficAnnotations.isEmpty {
                    map.removeAnnotations(Array(trafficAnnotations.values))
                    trafficAnnotations.removeAll()
                    trafficMembershipVersion = -1
                }
                return
            }

            // Add/remove only when membership changed.
            if store.membershipVersion != trafficMembershipVersion {
                trafficMembershipVersion = store.membershipVersion
                let live = Set(store.targets.keys)
                let stale = trafficAnnotations.filter { !live.contains($0.key) }
                if !stale.isEmpty {
                    map.removeAnnotations(Array(stale.values))
                    for key in stale.keys { trafficAnnotations[key] = nil }
                }
                for address in live where trafficAnnotations[address] == nil {
                    let annotation = TrafficAnnotation(address: address)
                    trafficAnnotations[address] = annotation
                    map.addAnnotation(annotation)
                }
            }

            // Refresh dynamics on every pass (cheap, in place).
            for (address, annotation) in trafficAnnotations {
                guard let target = store.targets[address] else { continue }
                annotation.update(from: target.report, ownshipAltitudeFt: ownshipAltitudeFt)
                if let view = map.view(for: annotation) as? TrafficAnnotationView {
                    view.annotation = annotation  // Redraw the data block.
                    view.updateRotation(map: map)
                }
            }
        }

        // MARK: Airport annotations

        nonisolated func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            MainActor.assumeIsolated {
                refreshAirportAnnotations(on: mapView)
                refreshAeronautical(on: mapView)
            }
        }

        func clearAirportAnnotations(on map: MKMapView) {
            map.removeAnnotations(Array(airportAnnotations.values))
            airportAnnotations.removeAll()
        }

        private func refreshAirportAnnotations(on map: MKMapView) {
            guard airportsEnabled, let db = aeroDatabase else { return }
            let region = map.region
            let span = max(region.span.latitudeDelta, region.span.longitudeDelta)
            // Importance-tiered density: only major airports far out,
            // everything as the user zooms in.
            let maxTier: Int
            let limit: Int
            switch span {
            case ..<1.5: maxTier = 2; limit = 80
            case ..<3.5: maxTier = 1; limit = 40
            case ..<8.0: maxTier = 0; limit = 15
            default:
                clearAirportAnnotations(on: map)
                return
            }
            annotationTask?.cancel()
            annotationTask = Task { [weak self, weak map] in
                guard let results = try? await db.mapAirportsNear(
                    latitude: region.center.latitude,
                    longitude: region.center.longitude,
                    spanDegrees: span / 2 + 0.1,
                    maxTier: maxTier,
                    limit: limit
                ), let self, let map, !Task.isCancelled else { return }

                var keep = Set<String>()
                for result in results {
                    keep.insert(result.id)
                    if self.airportAnnotations[result.id] == nil {
                        let annotation = AirportAnnotation(
                            airportId: result.displayIdentifier,
                            title: result.displayIdentifier,
                            coordinate: CLLocationCoordinate2D(latitude: result.latitude, longitude: result.longitude),
                            tier: result.tier
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
                if annotation is WaypointAnnotation {
                    return mapView.dequeueReusableAnnotationView(withIdentifier: WaypointAnnotationView.reuseId, for: annotation)
                }
                if annotation is RouteWaypointAnnotation {
                    return mapView.dequeueReusableAnnotationView(withIdentifier: RouteWaypointAnnotationView.reuseId, for: annotation)
                }
                if annotation is TrafficAnnotation {
                    return mapView.dequeueReusableAnnotationView(withIdentifier: TrafficAnnotationView.reuseId, for: annotation)
                }
                return nil
            }
        }

        nonisolated func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            MainActor.assumeIsolated {
                switch view.annotation {
                case let annotation as AirportAnnotation:
                    mapView.deselectAnnotation(annotation, animated: false)
                    onSelectAirport(annotation.airportId)
                case let annotation as RouteWaypointAnnotation where annotation.point.kind == "airport":
                    // Route markers outrank the regular airport annotations in
                    // collision, so a routed airport is tapped through its
                    // route marker.
                    mapView.deselectAnnotation(annotation, animated: false)
                    onSelectAirport(annotation.point.identifier)
                default:
                    break
                }
            }
        }
    }
}

// MARK: Annotations

final class AirportAnnotation: NSObject, MKAnnotation {
    let airportId: String
    let title: String?
    let coordinate: CLLocationCoordinate2D
    /// Importance tier from `AeroDatabase.MapAirport`: 0 major … 2 everything.
    let tier: Int

    init(airportId: String, title: String, coordinate: CLLocationCoordinate2D, tier: Int) {
        self.airportId = airportId
        self.title = title
        self.coordinate = coordinate
        self.tier = tier
    }
}

/// Airport symbol with its identifier lettered underneath, sized by
/// importance tier. Built from subviews (not the `image` property) so the
/// view's bounds enclose symbol + label and MapKit collision declutters the
/// label too.
final class AirportAnnotationView: MKAnnotationView {
    static let reuseId = "airport"

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
        let tier = (annotation as? AirportAnnotation)?.tier ?? 2
        let pointSize: CGFloat = tier == 0 ? 18 : tier == 1 ? 15 : 13
        let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        symbolView.image = UIImage(
            systemName: tier == 0 ? "circle.circle.fill" : "circle.circle",
            withConfiguration: config
        )?.withTintColor(.systemIndigo, renderingMode: .alwaysOriginal)
        symbolView.sizeToFit()

        label.attributedText = MapLabelStyle.halo(
            (annotation as? AirportAnnotation)?.airportId ?? "",
            font: .systemFont(ofSize: 13, weight: .bold),
            color: .systemIndigo
        )
        label.sizeToFit()

        MapLabelStyle.layoutSymbolAboveLabel(in: self, symbol: symbolView, label: label)
        canShowCallout = false
        displayPriority = MKFeatureDisplayPriority(rawValue: tier == 0 ? 800 : tier == 1 ? 600 : 400)
        collisionMode = .rectangle
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
