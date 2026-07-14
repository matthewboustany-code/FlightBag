import Foundation
import FBModels

/// Controlled and special-use airspace volumes for a map region.
public protocol AirspaceProviding: Sendable {
    /// Airspaces of the requested categories intersecting the bounding box
    /// (degrees; min/max latitude and longitude).
    func airspaces(
        categories: Set<Airspace.Category>,
        minLat: Double, minLon: Double, maxLat: Double, maxLon: Double
    ) async throws -> [Airspace]
}

/// Airspace from the FAA AIS ArcGIS feature services (28-day cycle data,
/// public domain): `Class_Airspace` for B/C/D, `Special_Use_Airspace` for
/// restricted/prohibited/warning areas.
public struct FAAAirspaceProvider: AirspaceProviding {
    private let http: any HTTPGetting
    private let baseURL: URL

    public init(
        http: any HTTPGetting = URLSessionHTTPClient(),
        baseURL: URL = URL(string: "https://services6.arcgis.com/ssFJjBXIUyZDrSYZ/arcgis/rest/services")!
    ) {
        self.http = http
        self.baseURL = baseURL
    }

    public func airspaces(
        categories: Set<Airspace.Category>,
        minLat: Double, minLon: Double, maxLat: Double, maxLon: Double
    ) async throws -> [Airspace] {
        let classCodes = categories.compactMap { category -> String? in
            switch category {
            case .classB: "B"
            case .classC: "C"
            case .classD: "D"
            default: nil
            }
        }
        let suaCodes = categories.compactMap { category -> String? in
            switch category {
            case .restricted: "R"
            case .prohibited: "P"
            case .warning: "W"
            default: nil
            }
        }

        // The layers share most fields but not all: IDENT is Class-only,
        // TIMESOFUSE is SUA-only — ArcGIS 400s on unknown outFields.
        let sharedFields = "NAME,CLASS,TYPE_CODE,LOWER_VAL,UPPER_VAL,LOWER_UOM,UPPER_UOM,LOWER_CODE,UPPER_CODE"
        async let classResult: Result<[Airspace], any Error> = classCodes.isEmpty ? .success([]) : attemptQuery(
            service: "Class_Airspace",
            where: "CLASS IN (\(sqlList(classCodes)))",
            outFields: sharedFields + ",IDENT",
            bbox: (minLon, minLat, maxLon, maxLat)
        )
        async let suaResult: Result<[Airspace], any Error> = suaCodes.isEmpty ? .success([]) : attemptQuery(
            service: "Special_Use_Airspace",
            where: "TYPE_CODE IN (\(sqlList(suaCodes)))",
            outFields: sharedFields + ",TIMESOFUSE",
            bbox: (minLon, minLat, maxLon, maxLat)
        )

        // One service failing must not blank the other's boundaries; throw
        // only when nothing succeeded.
        let results = await [classResult, suaResult]
        let successes = results.compactMap { try? $0.get() }
        if successes.isEmpty, let failure = results.compactMap(\.failure).first {
            throw failure
        }
        return successes.flatMap(\.self)
    }

    private func sqlList(_ values: [String]) -> String {
        values.map { "'\($0)'" }.joined(separator: ",")
    }

    private func attemptQuery(service: String, where whereClause: String, outFields: String, bbox: (Double, Double, Double, Double)) async -> Result<[Airspace], any Error> {
        do {
            return .success(try await query(service: service, where: whereClause, outFields: outFields, bbox: bbox))
        } catch {
            return .failure(error)
        }
    }

    private func query(service: String, where whereClause: String, outFields: String, bbox: (Double, Double, Double, Double)) async throws -> [Airspace] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("\(service)/FeatureServer/0/query"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "where", value: whereClause),
            URLQueryItem(name: "geometry", value: "\(bbox.0),\(bbox.1),\(bbox.2),\(bbox.3)"),
            URLQueryItem(name: "geometryType", value: "esriGeometryEnvelope"),
            URLQueryItem(name: "inSR", value: "4326"),
            URLQueryItem(name: "outSR", value: "4326"),
            URLQueryItem(name: "spatialRel", value: "esriSpatialRelIntersects"),
            URLQueryItem(name: "outFields", value: outFields),
            // Trim coordinate precision (~100 m) to shrink responses — the
            // service's rate limit charges by payload, and boundaries carry
            // thousands of vertices. maxAllowableOffset would generalize
            // further but nulls out geometries on this service.
            URLQueryItem(name: "geometryPrecision", value: "3"),
            URLQueryItem(name: "f", value: "geojson"),
        ]
        let data = try await http.get(components.url!)
        do {
            let collection = try JSONDecoder().decode(GeoJSONFeatureCollection.self, from: data)
            return collection.features.compactMap { $0.toAirspace() }
        } catch {
            // ArcGIS reports failures (e.g. rate limiting) as 200s with an
            // error envelope; surface its message instead of a decode error.
            if let envelope = try? JSONDecoder().decode(ArcGISErrorEnvelope.self, from: data) {
                let message = envelope.error.message.isEmpty
                    ? envelope.error.details?.first ?? "service error \(envelope.error.code)"
                    : envelope.error.message
                throw AirspaceProviderError.serviceError(message)
            }
            throw error
        }
    }
}

public enum AirspaceProviderError: Error, LocalizedError {
    case serviceError(String)

    public var errorDescription: String? {
        switch self {
        case .serviceError(let message): message
        }
    }
}

struct ArcGISErrorEnvelope: Decodable {
    struct Payload: Decodable {
        let code: Int
        let message: String
        let details: [String]?
    }
    let error: Payload
}

extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

// MARK: - GeoJSON decoding (just enough for ArcGIS polygon responses)

struct GeoJSONFeatureCollection: Decodable {
    let features: [GeoJSONFeature]
}

struct GeoJSONFeature: Decodable {
    struct Geometry: Decodable {
        let type: String
        let coordinates: GeoJSONCoordinates
    }

    struct Properties: Decodable {
        let NAME: String?
        let IDENT: String?
        let CLASS: String?
        let TYPE_CODE: String?
        let LOWER_VAL: FlexibleValue?
        let UPPER_VAL: FlexibleValue?
        let LOWER_UOM: String?
        let UPPER_UOM: String?
        let LOWER_CODE: String?
        let UPPER_CODE: String?
        let TIMESOFUSE: String?
    }

    let geometry: Geometry?
    let properties: Properties

    func toAirspace() -> Airspace? {
        guard let geometry, let category else { return nil }
        let rings = geometry.coordinates.outerRings(geometryType: geometry.type)
        guard !rings.isEmpty else { return nil }
        let name = properties.NAME ?? properties.IDENT ?? "AIRSPACE"
        return Airspace(
            id: "\(category.rawValue)-\(name)-\(altitudeText(properties.LOWER_VAL, properties.LOWER_UOM, properties.LOWER_CODE))",
            name: name,
            category: category,
            lowerText: altitudeText(properties.LOWER_VAL, properties.LOWER_UOM, properties.LOWER_CODE),
            upperText: altitudeText(properties.UPPER_VAL, properties.UPPER_UOM, properties.UPPER_CODE),
            timesOfUse: properties.TIMESOFUSE,
            polygons: rings
        )
    }

    private var category: Airspace.Category? {
        switch properties.CLASS ?? properties.TYPE_CODE {
        case "B": .classB
        case "C": .classC
        case "D": .classD
        case "R": .restricted
        case "P": .prohibited
        case "W": .warning
        default:
            switch properties.TYPE_CODE {
            case "R": .restricted
            case "P": .prohibited
            case "W": .warning
            default: nil
            }
        }
    }

    /// "0 FT SFC" → "SFC"; "4800 FT MSL" → "4,800 ft MSL"; UOM "FL" → "FL 180".
    private func altitudeText(_ value: FlexibleValue?, _ uom: String?, _ code: String?) -> String {
        guard let raw = value?.numeric else { return code ?? "—" }
        let amount = Int(raw)
        if amount == 0, code?.uppercased() == "SFC" || code == nil {
            return "SFC"
        }
        if uom?.uppercased() == "FL" {
            return "FL \(amount)"
        }
        let formatted = amount.formatted(.number.grouping(.automatic))
        return "\(formatted) ft \(code ?? "MSL")"
    }
}

/// Polygon (rings) or MultiPolygon (polygons of rings) coordinate payloads.
enum GeoJSONCoordinates: Decodable {
    case polygon([[[Double]]])
    case multiPolygon([[[[Double]]]])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let polygon = try? container.decode([[[Double]]].self) {
            self = .polygon(polygon)
        } else {
            self = .multiPolygon(try container.decode([[[[Double]]]].self))
        }
    }

    /// Outer ring of each polygon as coordinates (GeoJSON is lon,lat).
    func outerRings(geometryType: String) -> [[Coordinate]] {
        func ring(_ points: [[Double]]) -> [Coordinate]? {
            let coordinates = points.compactMap { pair -> Coordinate? in
                guard pair.count >= 2 else { return nil }
                return Coordinate(latitude: pair[1], longitude: pair[0])
            }
            return coordinates.count >= 3 ? coordinates : nil
        }
        switch self {
        case .polygon(let rings):
            return rings.first.flatMap(ring).map { [$0] } ?? []
        case .multiPolygon(let polygons):
            return polygons.compactMap { $0.first.flatMap(ring) }
        }
    }
}
