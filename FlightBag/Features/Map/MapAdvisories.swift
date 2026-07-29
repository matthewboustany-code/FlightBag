import Foundation
import MapKit
import FBModels

/// Advisory overlay categories with EFB-conventional colors.
enum AdvisoryCategory: String, CaseIterable, Identifiable {
    case tfr
    case sigmet
    case airmetSierra
    case airmetTango
    case airmetZulu
    case notam

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tfr: "TFRs"
        case .sigmet: "SIGMETs"
        case .airmetSierra: "AIRMET Sierra (IFR/Mtn)"
        case .airmetTango: "AIRMET Tango (Turb/Wind)"
        case .airmetZulu: "AIRMET Zulu (Icing)"
        case .notam: "NOTAMs"
        }
    }

    var strokeColor: UIColor {
        switch self {
        case .tfr: .systemRed
        case .sigmet: .systemRed
        case .airmetSierra: .systemPurple
        case .airmetTango: .systemBrown
        case .airmetZulu: .systemTeal
        // Deliberately not red: a NOTAM circle is an advisory area, not a
        // restriction, and must not be mistaken for a TFR at a glance.
        case .notam: .systemOrange
        }
    }

    var fillAlpha: CGFloat {
        switch self {
        case .tfr: 0.18
        // NOTAM circles overlap heavily around a busy field; a light fill
        // keeps the chart underneath readable.
        case .notam: 0.06
        default: 0.10
        }
    }
}

/// What a tapped advisory or airspace shows in the inspector sheet.
struct AdvisoryDisplayInfo: Identifiable, Hashable {
    var id = UUID()
    var color: UIColor
    var title: String
    var subtitle: String
    var detail: String
}

/// MKPolygon carrying its own rendering style plus details for
/// tap-to-inspect. Used by both hazard advisories and airspace volumes.
final class AdvisoryPolygon: MKPolygon {
    var info: AdvisoryDisplayInfo?
    var strokeColor: UIColor = .systemOrange
    var fillAlpha: CGFloat = 0.10
    var isDashed = false

    static func make(coordinates: [Coordinate], category: AdvisoryCategory, title: String, subtitle: String, detail: String) -> AdvisoryPolygon {
        var points = coordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        let polygon = AdvisoryPolygon(coordinates: &points, count: points.count)
        polygon.strokeColor = category.strokeColor
        polygon.fillAlpha = category.fillAlpha
        polygon.info = AdvisoryDisplayInfo(color: category.strokeColor, title: title, subtitle: subtitle, detail: detail)
        return polygon
    }
}

enum AdvisoryOverlayBuilder {
    // Filtered views of the store, shared by overlay building and the layer
    // panel's counts so the numbers always match what's drawn.

    @MainActor
    static func visibleTFRAreas(layers: MapLayersState, store: AdvisoryStore) -> [(tfr: TemporaryFlightRestriction, area: TemporaryFlightRestriction.Area)] {
        store.tfrs.flatMap { tfr in
            tfr.areas
                .filter { layers.passesAltitudeFilter($0.altitudeBand) }
                .map { (tfr, $0) }
        }
    }

    @MainActor
    static func visibleSigmets(layers: MapLayersState, store: AdvisoryStore) -> [WeatherAdvisory] {
        store.airSigmets.filter { layers.passesAltitudeFilter($0.altitudeBand) }
    }

    @MainActor
    static func visibleAirmets(_ product: GraphicalAirmet.Product, layers: MapLayersState, store: AdvisoryStore) -> [GraphicalAirmet] {
        store.gAirmets.filter {
            $0.product == product && $0.isArea && $0.polygon.count >= 3
                && layers.passesAltitudeFilter($0.altitudeBand)
        }
    }

    /// NOTAMs that can actually be drawn: active, with a published centre and
    /// radius, and not already on the map as a TFR.
    ///
    /// The TFR check matters — `FAATFRProvider` sources from NOTAM data, so
    /// without it a single restriction draws twice in two different colours,
    /// which reads as two separate hazards.
    @MainActor
    static func visibleNotams(layers: MapLayersState, notams: [Notam], store: AdvisoryStore) -> [Notam] {
        let tfrIds = Set(store.tfrs.map(\.id))
        var seen = Set<String>()
        return notams.filter { notam in
            guard notam.mapCircle != nil, notam.isActive(), !tfrIds.contains(notam.id) else { return false }
            // The same NOTAM can arrive for several route airports.
            return seen.insert(notam.id).inserted
        }
    }

    /// Overlays for every enabled advisory category.
    @MainActor
    static func overlays(
        layers: MapLayersState,
        store: AdvisoryStore,
        notams: [Notam] = []
    ) -> [AdvisoryPolygon] {
        var result: [AdvisoryPolygon] = []

        if layers.notamsEnabled {
            for notam in visibleNotams(layers: layers, notams: notams, store: store) {
                guard let circle = notam.mapCircle else { continue }
                let limits = [
                    notam.lowerLimitFt.map { "from \($0) ft" },
                    notam.upperLimitFt.map { "to \($0) ft" },
                ].compactMap(\.self).joined(separator: " ")
                result.append(AdvisoryPolygon.make(
                    coordinates: Self.circlePolygon(centre: circle.centre, radiusNM: circle.radiusNM),
                    category: .notam,
                    title: "NOTAM \(notam.id) · \(notam.location.rawValue)",
                    subtitle: [
                        limits.isEmpty ? nil : limits,
                        notam.endIsEstimated
                            ? "no end time"
                            : notam.effectiveEnd.map { "until \(Self.time($0))" },
                    ].compactMap(\.self).joined(separator: " · "),
                    detail: notam.text
                ))
            }
        }

        if layers.tfrsEnabled {
            for (tfr, area) in visibleTFRAreas(layers: layers, store: store) {
                let limits = [area.floorText, area.ceilingText].compactMap(\.self).joined(separator: " – ")
                result.append(AdvisoryPolygon.make(
                    coordinates: area.polygon,
                    category: .tfr,
                    title: "TFR \(tfr.id)\(tfr.type.map { " · \($0)" } ?? "")",
                    subtitle: [area.name, limits.isEmpty ? nil : limits].compactMap(\.self).joined(separator: " · "),
                    detail: tfr.description
                ))
            }
        }

        if layers.sigmetsEnabled {
            for advisory in visibleSigmets(layers: layers, store: store) {
                let altitudes = [
                    advisory.altitudeLowFt.map { "from \($0) ft" },
                    advisory.altitudeHiFt.map { "to \($0) ft" },
                ].compactMap(\.self).joined(separator: " ")
                result.append(AdvisoryPolygon.make(
                    coordinates: advisory.polygon,
                    category: .sigmet,
                    title: "\(advisory.kind.rawValue) · \(advisory.hazard)",
                    subtitle: [altitudes.isEmpty ? nil : altitudes, "until \(Self.time(advisory.validTo))"]
                        .compactMap(\.self).joined(separator: " · "),
                    detail: advisory.rawText
                ))
            }
        }

        let productToggles: [(GraphicalAirmet.Product, Bool, AdvisoryCategory)] = [
            (.sierra, layers.airmetSierraEnabled, .airmetSierra),
            (.tango, layers.airmetTangoEnabled, .airmetTango),
            (.zulu, layers.airmetZuluEnabled, .airmetZulu),
        ]
        for (product, enabled, category) in productToggles where enabled {
            // Area polygons only; freezing-level contours are lines.
            for airmet in visibleAirmets(product, layers: layers, store: store) {
                let altitudes = [
                    airmet.base.map { "base \($0)" },
                    airmet.top.map { "top \($0)" },
                ].compactMap(\.self).joined(separator: " · ")
                result.append(AdvisoryPolygon.make(
                    coordinates: airmet.polygon,
                    category: category,
                    title: "G-AIRMET \(airmet.product.rawValue.capitalized) · \(airmet.hazard)",
                    subtitle: [
                        altitudes.isEmpty ? nil : altitudes,
                        airmet.severity.map { "severity \($0)" },
                        "until \(Self.time(airmet.expireTime))",
                    ].compactMap(\.self).joined(separator: " · "),
                    detail: airmet.dueTo.map { "Due to: \($0)" } ?? ""
                ))
            }
        }

        return result
    }

    private static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// A circle as a polygon ring.
    ///
    /// NOTAM areas are published as centre + radius, but drawing them as
    /// `MKCircle` would need a second renderer and a second tap path in the
    /// map Coordinator. Approximating as a polygon reuses `AdvisoryPolygon`
    /// wholesale — same styling, same tap-to-inspect, same z-ordering. At 48
    /// segments the error against a true circle is under 0.3%, far below
    /// chart resolution.
    static func circlePolygon(centre: Coordinate, radiusNM: Double, segments: Int = 48) -> [Coordinate] {
        let radiusDegrees = radiusNM / 60.0
        let latitudeRadians = centre.latitude * .pi / 180
        // Longitude degrees shrink with latitude; without this the circle
        // draws as an ellipse everywhere but the equator.
        let longitudeScale = max(cos(latitudeRadians), 0.01)

        return (0..<segments).map { step in
            let angle = 2 * .pi * Double(step) / Double(segments)
            return Coordinate(
                latitude: centre.latitude + radiusDegrees * cos(angle),
                longitude: centre.longitude + radiusDegrees * sin(angle) / longitudeScale
            )
        }
    }
}
