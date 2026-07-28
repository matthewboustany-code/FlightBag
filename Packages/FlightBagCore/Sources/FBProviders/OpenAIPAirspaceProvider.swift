import Foundation
import FBModels

/// Worldwide airspace from openAIP.
///
/// **Licence:** openAIP data is CC BY-NC — non-commercial, attribution
/// required (`DataAuthority.openAIP.attribution`). It is the only
/// NC-encumbered source FlightBag uses, which is why it lives behind its own
/// conformer: swapping it out later means replacing this one file, not
/// reworking every consumer.
///
/// **Auth:** needs an API key from the openAIP profile page, sent as
/// `x-openaip-api-key`. Without one the provider reports
/// `OpenAIPError.missingAPIKey` rather than silently returning nothing, so a
/// blank airspace layer is never mistaken for "no airspace here".
///
/// The `type` and `icaoClass` mappings below come from openAIP's published
/// OpenAPI schema (`/api/system/specs/v1/schema.json`), not from guesswork.
public struct OpenAIPAirspaceProvider: AirspaceProviding {
    private let http: any HTTPGetting
    private let baseURL: URL
    private let apiKey: String?

    public init(
        http: any HTTPGetting = URLSessionHTTPClient(),
        apiKey: String?,
        baseURL: URL = URL(string: "https://api.core.openaip.net/api")!
    ) {
        self.http = http
        self.apiKey = apiKey
        self.baseURL = baseURL
    }

    /// openAIP `icaoClass` values → the categories FlightBag draws.
    /// 0:A 1:B 2:C 3:D 4:E 5:F 6:G 8:Unclassified/SUA.
    static func category(icaoClass: Int?, type: Int?) -> Airspace.Category? {
        // A specific SUA type wins over the ICAO class, because SUA volumes
        // report icaoClass 8 ("unclassified") and the type is what carries
        // the meaning a pilot needs.
        switch type {
        case 1: return .restricted
        case 2: return .danger
        case 3: return .prohibited
        case 18: return .warning
        default: break
        }
        switch icaoClass {
        case 1: return .classB
        case 2: return .classC
        case 3: return .classD
        default: return nil
        }
    }

    /// openAIP `type` values FlightBag asks for, matching the categories it
    /// can draw. 1:Restricted 2:Danger 3:Prohibited 18:Warning.
    static func queryTypes(for categories: Set<Airspace.Category>) -> [Int] {
        categories.compactMap { category in
            switch category {
            case .restricted: 1
            case .danger: 2
            case .prohibited: 3
            case .warning: 18
            case .classB, .classC, .classD: nil
            }
        }.sorted()
    }

    static func queryClasses(for categories: Set<Airspace.Category>) -> [Int] {
        categories.compactMap { category in
            switch category {
            case .classB: 1
            case .classC: 2
            case .classD: 3
            case .restricted, .prohibited, .warning, .danger: nil
            }
        }.sorted()
    }

    public func airspaces(
        categories: Set<Airspace.Category>,
        minLat: Double, minLon: Double, maxLat: Double, maxLon: Double
    ) async throws -> [Airspace] {
        guard let apiKey, !apiKey.isEmpty else { throw OpenAIPError.missingAPIKey }
        guard !categories.isEmpty else { return [] }

        var components = URLComponents(url: baseURL.appendingPathComponent("airspaces"), resolvingAgainstBaseURL: false)!
        // openAIP's bbox is minx,miny,maxx,maxy — longitude first, despite the
        // parameter being described as "lat/lon values".
        var items = [
            URLQueryItem(name: "bbox", value: "\(minLon),\(minLat),\(maxLon),\(maxLat)"),
            URLQueryItem(name: "limit", value: "1000"),
        ]
        let types = Self.queryTypes(for: categories)
        let classes = Self.queryClasses(for: categories)
        // Asking for neither would return every airspace in the box; asking
        // for both is an AND at the API, so we filter client-side instead when
        // the user wants a mix.
        if classes.isEmpty && !types.isEmpty {
            items.append(URLQueryItem(name: "type", value: types.map(String.init).joined(separator: ",")))
        } else if types.isEmpty && !classes.isEmpty {
            items.append(URLQueryItem(name: "icaoClass", value: classes.map(String.init).joined(separator: ",")))
        }
        components.queryItems = items

        let data = try await http.get(components.url!, headers: ["x-openaip-api-key": apiKey])
        let response = try JSONDecoder().decode(OpenAIPAirspaceResponse.self, from: data)
        return response.items.compactMap { $0.toAirspace() }.filter { categories.contains($0.category) }
    }
}

public enum OpenAIPError: Error, CustomStringConvertible {
    case missingAPIKey

    public var description: String {
        switch self {
        case .missingAPIKey:
            "No openAIP API key configured — worldwide airspace is unavailable."
        }
    }
}

struct OpenAIPAirspaceResponse: Decodable {
    let items: [OpenAIPAirspace]
}

struct OpenAIPAirspace: Decodable {
    let _id: String?
    let name: String?
    let type: Int?
    let icaoClass: Int?
    let country: String?
    let upperLimit: OpenAIPLimit?
    let lowerLimit: OpenAIPLimit?
    let geometry: OpenAIPGeometry?

    func toAirspace() -> Airspace? {
        guard let category = OpenAIPAirspaceProvider.category(icaoClass: icaoClass, type: type),
              let polygons = geometry?.rings, !polygons.isEmpty else { return nil }
        return Airspace(
            id: _id ?? "\(name ?? "airspace")-\(country ?? "")",
            name: name ?? "Unnamed airspace",
            category: category,
            lowerText: lowerLimit?.text ?? "",
            upperText: upperLimit?.text ?? "",
            polygons: polygons
        )
    }
}

/// An altitude limit.
///
/// The response object's `unit` and `referenceDatum` codes are **not** in
/// openAIP's published OpenAPI schema, so the mappings below are inferred from
/// their data model rather than verified against the spec. Anything
/// unrecognised produces an empty string, which `AltitudeBand.feet(fromText:)`
/// reads as unbounded — and an unbounded advisory is never hidden by the
/// altitude filter. That is the safe direction to fail: a volume shown when it
/// need not be, rather than hidden when it matters.
struct OpenAIPLimit: Decodable {
    let value: Double?
    let unit: Int?
    let referenceDatum: Int?

    var text: String {
        guard let value else { return "" }
        switch unit {
        case 0: return "\(Int(value)) m\(datumSuffix)"
        case 1: return "\(Int(value)) ft\(datumSuffix)"
        case 6: return "FL \(Int(value))"
        default: return ""
        }
    }

    private var datumSuffix: String {
        switch referenceDatum {
        case 0: return value == 0 ? " SFC" : " AGL"
        case 1: return " MSL"
        default: return ""
        }
    }
}

/// Reuses `GeoJSONCoordinates` from the FAA provider — same GeoJSON shapes,
/// same lon/lat ordering to get right, no reason for a second decoder.
struct OpenAIPGeometry: Decodable {
    let type: String?
    let coordinates: GeoJSONCoordinates?

    var rings: [[Coordinate]]? {
        guard let coordinates, let type else { return nil }
        let outer = coordinates.outerRings(geometryType: type)
        return outer.isEmpty ? nil : outer
    }
}
