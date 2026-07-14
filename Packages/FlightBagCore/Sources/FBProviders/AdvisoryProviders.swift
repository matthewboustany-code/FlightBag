import Foundation
import FBModels

/// Weather hazard advisories (SIGMET/AIRMET + graphical AIRMET) for map
/// overlays.
public protocol AdvisoryProvider: Sendable {
    func airSigmets() async throws -> [WeatherAdvisory]
    func graphicalAirmets() async throws -> [GraphicalAirmet]
}

extension AviationWeatherGovProvider: AdvisoryProvider {
    public func airSigmets() async throws -> [WeatherAdvisory] {
        var components = URLComponents(url: baseURL.appendingPathComponent("airsigmet"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "format", value: "json")]
        let data = try await http.get(components.url!)
        let raw = try JSONDecoder().decode([AWCAirSigmet].self, from: data)
        return raw.compactMap { $0.toAdvisory() }
    }

    public func graphicalAirmets() async throws -> [GraphicalAirmet] {
        var components = URLComponents(url: baseURL.appendingPathComponent("gairmet"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "format", value: "json")]
        let data = try await http.get(components.url!)
        let raw = try JSONDecoder().decode([AWCGAirmet].self, from: data)
        return raw.compactMap { $0.toAirmet() }
    }
}

/// A latitude/longitude pair that arrives as numbers (airsigmet) or strings
/// (gairmet).
struct AWCCoordinate: Decodable {
    let lat: FlexibleValue
    let lon: FlexibleValue

    var coordinate: Coordinate? {
        guard let lat = lat.numeric, let lon = lon.numeric else { return nil }
        return Coordinate(latitude: lat, longitude: lon)
    }
}

struct AWCAirSigmet: Decodable {
    let icaoId: String?
    let alphaChar: String?
    let seriesId: String?
    let airSigmetType: String
    let hazard: String?
    let validTimeFrom: Double
    let validTimeTo: Double
    let altitudeLow1: Int?
    let altitudeLow2: Int?
    let altitudeHi1: Int?
    let altitudeHi2: Int?
    let rawAirSigmet: String?
    let coords: [AWCCoordinate]?

    func toAdvisory() -> WeatherAdvisory? {
        guard let kind = WeatherAdvisory.Kind(rawValue: airSigmetType.uppercased()) else { return nil }
        let polygon = (coords ?? []).compactMap(\.coordinate)
        guard polygon.count >= 3 else { return nil }
        return WeatherAdvisory(
            id: [airSigmetType, seriesId ?? alphaChar ?? "", String(Int(validTimeFrom))].joined(separator: "-"),
            kind: kind,
            hazard: hazard ?? "UNKNOWN",
            validFrom: Date(timeIntervalSince1970: validTimeFrom),
            validTo: Date(timeIntervalSince1970: validTimeTo),
            altitudeLowFt: altitudeLow1 ?? altitudeLow2,
            altitudeHiFt: altitudeHi1 ?? altitudeHi2,
            rawText: rawAirSigmet ?? "",
            polygon: polygon
        )
    }
}

struct AWCGAirmet: Decodable {
    let tag: String?
    let product: String
    let hazard: String?
    let validTime: String
    let expireTime: Double?
    let forecastHour: Int?
    let severity: String?
    let top: String?
    let base: String?
    let dueTo: String?
    let geom: String?
    let coords: [AWCCoordinate]?

    private enum CodingKeys: String, CodingKey {
        case tag, product, hazard, validTime, expireTime, forecastHour, severity, top, base, geom, coords
        case dueTo = "due_to"
    }

    func toAirmet() -> GraphicalAirmet? {
        guard let product = GraphicalAirmet.Product(rawValue: product.uppercased()) else { return nil }
        let polygon = (coords ?? []).compactMap(\.coordinate)
        guard polygon.count >= 2,
              let valid = try? Date(validTime, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
                ?? Date(validTime, strategy: .iso8601) else { return nil }
        return GraphicalAirmet(
            id: "\(product.rawValue)-\(tag ?? "")-\(validTime)",
            product: product,
            hazard: hazard ?? "UNKNOWN",
            validTime: valid,
            expireTime: expireTime.map { Date(timeIntervalSince1970: $0) } ?? valid.addingTimeInterval(3 * 3600),
            forecastHour: forecastHour ?? 0,
            severity: severity,
            top: top,
            base: base,
            dueTo: dueTo,
            isArea: (geom ?? "AREA").uppercased() != "LINE",
            polygon: polygon
        )
    }
}
