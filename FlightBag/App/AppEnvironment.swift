import Foundation
import Observation
import FBModels
import FBFlightPlan
import FBProviders
import FBGDL90
import FBFISB

/// A planned route pushed onto the map from a flight's detail page.
/// Carries identified points (not bare coordinates) so the map can label
/// them and the route editor panel can add/remove/reorder.
struct ActiveMapRoute: Hashable {
    struct Point: Hashable, Identifiable {
        let id = UUID()
        var identifier: String
        var coordinate: Coordinate
        /// `ResolvedWaypoint.Kind` rawValue: airport/navaid/fix/latLon.
        var kind: String
        /// Airway this point was expanded from ("V17"), nil for explicit points.
        var airway: String?
    }

    var label: String
    var points: [Point]

    var coordinates: [Coordinate] { points.map(\.coordinate) }

    init(label: String, points: [Point]) {
        self.label = label
        self.points = points
    }

    /// Flattens a parsed route, tagging airway intermediates with the
    /// airway they came from.
    init(label: String, route: ParsedRoute) {
        self.label = label
        points = route.elements.flatMap { element -> [Point] in
            switch element {
            case .waypoint(let wp):
                return [Point(identifier: wp.identifier, coordinate: wp.coordinate, kind: wp.kind.rawValue, airway: nil)]
            case .airway(let ident, let via):
                return via.map { Point(identifier: $0.identifier, coordinate: $0.coordinate, kind: $0.kind.rawValue, airway: ident) }
            case .direct, .unresolved:
                return []
            }
        }
    }
}

/// A SID/STAR drawn on the map from CIFP geometry: the common route plus
/// every transition, one branch each. Branches share junction fixes, so the
/// drawn lines connect; the paper chart's "all transitions" view.
struct ActiveMapProcedure: Hashable {
    struct Branch: Hashable {
        var label: String
        var points: [ActiveMapRoute.Point]
    }

    /// e.g. "KAUS AEROZ2 (SID)".
    var label: String
    var branches: [Branch]

    /// Every fix once, for annotations.
    var uniquePoints: [ActiveMapRoute.Point] {
        var seen = Set<String>()
        return branches.flatMap(\.points).filter { seen.insert($0.identifier).inserted }
    }

    /// Assemble from `AeroDatabase.procedureLegs` rows (already ordered by
    /// transition, then sequence).
    init(airportDisplayId: String, ident: String, kind: String, legs: [AeroDatabase.ProcedureLegRow]) {
        label = "\(airportDisplayId) \(ident) (\(kind.uppercased()))"
        let grouped = Dictionary(grouping: legs) { "\($0.transitionKind)|\($0.transitionIdent ?? "")" }
        branches = grouped
            .sorted { $0.key < $1.key }
            .map { _, groupLegs in
                Branch(
                    label: groupLegs[0].transitionIdent ?? "common",
                    points: groupLegs
                        .sorted { $0.seq < $1.seq }
                        .map {
                            ActiveMapRoute.Point(
                                identifier: $0.fixIdent,
                                coordinate: Coordinate(latitude: $0.latitude, longitude: $0.longitude),
                                kind: "fix",
                                airway: nil
                            )
                        }
                )
            }
            .filter { $0.points.count >= 2 }
    }
}

/// Dependency container injected at the app root. Features reach services
/// through this — never through singletons — so previews and tests can swap
/// implementations.
@MainActor
@Observable
final class AppEnvironment {
    /// nil only if the bundled database is missing/corrupt; UI shows a
    /// degraded state rather than crashing.
    let aeroDatabase: AeroDatabase?
    let weatherStore: WeatherStore
    let plateStore: PlateStore
    let chartStore = ChartStore()
    let downloadCenter = DownloadCenter()
    let filingService: any FilingService
    let advisoryStore = AdvisoryStore()
    let airspaceStore = AirspaceStore()
    let gdl90Receiver = GDL90Receiver()
    let gdl90PositionSource = GDL90PositionSource()
    let trafficStore = TrafficStore()
    let fisbRadarStore = FISBRadarStore()
    /// ADS-B preferred, CoreLocation fallback; the only position source
    /// views should touch.
    let positionSource: CompositePositionSource

    /// `-weatherDemoOffline YES` simulates no connectivity, so cached and
    /// FIS-B weather can be exercised in the simulator.
    nonisolated static func defaultWeatherProvider() -> any WeatherProvider {
        UserDefaults.standard.bool(forKey: "weatherDemoOffline")
            ? OfflineWeatherProvider()
            : AviationWeatherGovProvider()
    }

    /// Bumped when FIS-B text lands in the weather cache, so open airport
    /// screens pick up uplinked weather without a manual refresh.
    private(set) var fisbWeatherVersion = 0

    /// Route drawn on the map tab; set from a flight, cleared from the map.
    var activeMapRoute: ActiveMapRoute?
    /// Approach plate pinned to the map; set from the plate viewer, cleared
    /// from the map (or automatically if the chart can't be loaded).
    var activePlateOverlay: PlateMetadata?
    /// SID/STAR drawn as vector branches on the map — a read-only preview,
    /// deliberately separate from the editable `activeMapRoute`.
    var activeProcedure: ActiveMapProcedure?
    /// One-shot tab-switch request ("Show on map"); RootTabView consumes it.
    var requestedTab: AppTab?

    init(
        weatherProvider: any WeatherProvider = AppEnvironment.defaultWeatherProvider(),
        filingService: any FilingService = LocalDraftFilingService()
    ) {
        self.aeroDatabase = try? AeroDatabase.open()
        self.weatherStore = WeatherStore(provider: weatherProvider)
        self.plateStore = PlateStore()
        self.filingService = filingService
        self.positionSource = CompositePositionSource(
            primary: gdl90PositionSource,
            fallback: CoreLocationPositionSource()
        )

        gdl90Receiver.onOwnship = { [gdl90PositionSource, trafficStore] report in
            gdl90PositionSource.ingest(report: report)
            // A receiver reports the ship it's installed in; suppress the echo.
            trafficStore.ownshipAddress = report.address
        }
        gdl90Receiver.onOwnshipGeoAltitude = { [gdl90PositionSource] feet in
            gdl90PositionSource.ingest(geometricAltitudeFeet: feet)
        }
        gdl90Receiver.onTraffic = { [trafficStore] report in
            trafficStore.ingest(report: report)
        }
        gdl90Receiver.onFISB = { [weak self, fisbRadarStore, weatherStore] product in
            switch product {
            case .nexrad(let radar):
                fisbRadarStore.ingest(radar)
            case .text(let reports):
                Task { @MainActor in
                    await weatherStore.ingestFISB(reports: reports)
                    self?.fisbWeatherVersion += 1
                }
            default:
                break
            }
        }
        gdl90Receiver.onTick = { [weak self] _ in
            guard let self else { return }
            self.gdl90PositionSource.updateCurrency(heartbeatGPSValid: self.gdl90Receiver.gpsPositionValid)
            self.trafficStore.prune()
            self.fisbRadarStore.expire()
        }
    }
}
