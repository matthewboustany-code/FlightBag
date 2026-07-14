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

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tfr: "TFRs"
        case .sigmet: "SIGMETs"
        case .airmetSierra: "AIRMET Sierra (IFR/Mtn)"
        case .airmetTango: "AIRMET Tango (Turb/Wind)"
        case .airmetZulu: "AIRMET Zulu (Icing)"
        }
    }

    var strokeColor: UIColor {
        switch self {
        case .tfr: .systemRed
        case .sigmet: .systemOrange
        case .airmetSierra: .systemPurple
        case .airmetTango: .systemBrown
        case .airmetZulu: .systemTeal
        }
    }

    var fillAlpha: CGFloat {
        self == .tfr ? 0.18 : 0.10
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
    /// Overlays for every enabled advisory category.
    @MainActor
    static func overlays(layers: MapLayersState, store: AdvisoryStore) -> [AdvisoryPolygon] {
        var result: [AdvisoryPolygon] = []

        if layers.tfrsEnabled {
            for tfr in store.tfrs {
                for area in tfr.areas {
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
        }

        if layers.sigmetsEnabled {
            for advisory in store.airSigmets {
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
            for airmet in store.gAirmets where airmet.product == product && airmet.isArea && airmet.polygon.count >= 3 {
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
}
