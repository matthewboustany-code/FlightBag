import SwiftUI
import FBModels
import FBFlightPlan
import FBProviders

/// Leg-by-leg navigation log: course, distance, ground speed, ETE, and fuel,
/// with winds aloft applied from the nearest FB forecast station.
struct NavLogView: View {
    let flight: Flight
    let parsedRoute: ParsedRoute?
    @Environment(AppEnvironment.self) private var environment

    @State private var navLog: NavLog?
    @State private var windsApplied = false
    @State private var loading = true
    @AppStorage(UnitSystemPreference.defaultsKey) private var unitSystem = UnitSystemPreference.automatic.rawValue

    /// A route can cross jurisdictions, so there is no single "local"
    /// convention to follow — the navlog uses the ambient setting.
    private var units: UnitPreferences {
        (UnitSystemPreference(rawValue: unitSystem) ?? .automatic)
            .preferences(for: UnitSystemPreference.deviceJurisdiction)
    }

    var body: some View {
        Group {
            if let navLog, !navLog.legs.isEmpty {
                List {
                    Section {
                        ForEach(navLog.legs) { leg in
                            NavLogLegRow(leg: leg, units: units)
                        }
                    } footer: {
                        Label(
                            windsApplied
                                ? "Winds aloft: FB forecast via aviationweather.gov, nearest station per leg."
                                : "No winds applied (offline or no forecast) — times assume calm air.",
                            systemImage: windsApplied ? "wind" : "wind.slash"
                        )
                    }

                    Section("Totals") {
                        LabeledContent("Distance", value: units.formatDistance(nauticalMiles: navLog.totalDistanceNM))
                        if let ete = navLog.totalEteSeconds {
                            LabeledContent("Time en route", value: Self.hhmm(ete))
                        }
                        if let fuel = navLog.totalFuelGallons {
                            LabeledContent("Fuel", value: String(format: "%.1f gal", fuel))
                        }
                        if navLog.totalEteSeconds == nil {
                            Text("Add an aircraft with cruise speed for ETE and fuel.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else if loading {
                ProgressView("Building navlog…")
            } else {
                ContentUnavailableView(
                    "No Route",
                    systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                    description: Text("Enter departure, route, and destination that resolve to at least two waypoints.")
                )
            }
        }
        .navigationTitle("Navigation Log")
        .navigationBarTitleDisplayMode(.inline)
        .task { await build() }
    }

    private func build() async {
        defer { loading = false }
        guard let parsedRoute, parsedRoute.waypoints.count >= 2 else { return }

        let tas = flight.aircraft.map { Double($0.cruiseTrueAirspeedKt) }
        let burn = flight.aircraft?.fuelBurnGph

        // Winds: FB stations are mostly VORs, so their coordinates resolve
        // straight out of the navaid table. Failure just means calm-air times.
        var located: [(Coordinate, WindsAloftStation)] = []
        if let db = environment.aeroDatabase,
           let stations = try? await AviationWeatherGovProvider().windsAloft(forecastHours: 6) {
            for station in stations {
                if let waypoint = try? await db.resolveWaypoint(identifier: station.identifier) {
                    located.append((waypoint.coordinate, station))
                }
            }
        }
        let altitude = Self.cruiseAltitudeFeet(from: flight.flightPlanData) ?? 6000
        windsApplied = !located.isEmpty

        navLog = NavLogBuilder.build(
            route: parsedRoute,
            cruiseTASKt: (tas ?? 0) > 0 ? tas : nil,
            fuelBurnGPH: (burn ?? 0) > 0 ? burn : nil
        ) { midpoint in
            guard let nearest = located.min(by: { a, b in
                Self.roughDistance(a.0, midpoint) < Self.roughDistance(b.0, midpoint)
            }) else { return nil }
            guard let entry = nearest.1.entryNearest(altitudeFt: altitude),
                  let direction = entry.fromDegrees else { return nil }
            return LegWind(fromDegrees: direction, speedKt: entry.speedKt)
        }
    }

    /// Planned cruising level → feet.
    ///
    /// ICAO item 15 allows metric forms as well as the familiar imperial ones,
    /// and the validator already accepts them: "S1130"/"M0840" are tens of
    /// metres (S1130 = 11 300 m). Without this branch a metric-level plan
    /// returned nil and silently lost its winds-aloft application.
    static func cruiseAltitudeFeet(from planData: Data?) -> Int? {
        guard let plan = FlightPlanCodec.decode(planData) else { return nil }
        let level = plan.cruisingLevel
        guard let prefix = level.first else { return nil }
        switch prefix {
        case "A", "F":
            guard level.count == 4, let hundreds = Int(level.dropFirst()) else { return nil }
            return hundreds * 100
        case "S", "M":
            guard level.count == 5, let tensOfMetres = Int(level.dropFirst()) else { return nil }
            return Int((Double(tensOfMetres) * 10 / 0.3048).rounded())
        default:
            return nil
        }
    }

    private static func roughDistance(_ a: Coordinate, _ b: Coordinate) -> Double {
        let dLat = a.latitude - b.latitude
        let dLon = (a.longitude - b.longitude) * cos(a.latitude * .pi / 180)
        return dLat * dLat + dLon * dLon
    }

    private static func hhmm(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }
}

private struct NavLogLegRow: View {
    let leg: NavLogLeg
    let units: UnitPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(leg.from.identifier)
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(leg.to.identifier)
                Spacer()
                Text("\(Int(leg.courseTrue.rounded()))°T")
                    .foregroundStyle(.secondary)
            }
            .font(.callout.monospaced().bold())

            HStack(spacing: 12) {
                stat("Dist", units.formatDistance(nauticalMiles: leg.distanceNM))
                if let gs = leg.groundSpeedKt {
                    stat("GS", units.formatSpeed(knots: gs))
                }
                if let ete = leg.eteSeconds {
                    stat("ETE", "\(Int((ete / 60).rounded())) min")
                }
                if let fuel = leg.fuelGallons {
                    stat("Fuel", String(format: "%.1f gal", fuel))
                }
                if let dir = leg.windFromDegrees, let speed = leg.windSpeedKt {
                    stat("Wind", "\(Int(dir))@\(Int(speed))")
                }
            }
            .font(.caption)
        }
        .padding(.vertical, 2)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .monospacedDigit()
        }
    }
}
