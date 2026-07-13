import Foundation
import FBModels

/// FAA/NWS weather from the aviationweather.gov Data API (free, no key).
/// https://aviationweather.gov/data/api/
public struct AviationWeatherGovProvider: WeatherProvider {
    private let http: any HTTPGetting
    private let baseURL: URL

    public init(http: any HTTPGetting = URLSessionHTTPClient(), baseURL: URL = URL(string: "https://aviationweather.gov/api/data")!) {
        self.http = http
        self.baseURL = baseURL
    }

    public func metar(for station: ICAOIdentifier) async throws -> Metar? {
        try await metars(for: [station]).first
    }

    public func metars(for stations: [ICAOIdentifier]) async throws -> [Metar] {
        guard !stations.isEmpty else { return [] }
        let url = endpoint("metar", ids: stations)
        let data = try await http.get(url)
        let raw = try Self.decoder.decode([AWCMetar].self, from: data)
        return raw.map { $0.toMetar() }
    }

    public func taf(for station: ICAOIdentifier) async throws -> Taf? {
        let url = endpoint("taf", ids: [station])
        let data = try await http.get(url)
        let raw = try Self.decoder.decode([AWCTaf].self, from: data)
        return raw.first.map { $0.toTaf() }
    }

    private func endpoint(_ product: String, ids: [ICAOIdentifier]) -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent(product), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "ids", value: ids.map(\.rawValue).joined(separator: ",")),
            URLQueryItem(name: "format", value: "json"),
        ]
        return components.url!
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            // The API mixes epoch seconds and ISO8601 strings across fields.
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }
            let string = try container.decode(String.self)
            if let date = try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
                return date
            }
            if let date = try? Date(string, strategy: .iso8601) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognized date: \(string)")
        }
        return decoder
    }
}

/// A JSON value that may arrive as a number or a string ("VRB", "10+", …).
enum FlexibleValue: Decodable {
    case number(Double)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    var numeric: Double? {
        switch self {
        case .number(let value): return value
        case .string(let string): return Double(string.trimmingCharacters(in: CharacterSet(charactersIn: "+")))
        }
    }

    var isAtLeast: Bool {
        if case .string(let string) = self { return string.hasSuffix("+") }
        return false
    }

    var isVariable: Bool {
        if case .string(let string) = self { return string.uppercased() == "VRB" }
        return false
    }
}

struct AWCMetar: Decodable {
    let icaoId: String
    let rawOb: String
    let obsTime: Date?
    let temp: Double?
    let dewp: Double?
    let wdir: FlexibleValue?
    let wspd: Int?
    let wgst: Int?
    let visib: FlexibleValue?
    let altim: Double?
    let wxString: String?
    let clouds: [AWCCloud]?
    let fltCat: String?

    struct AWCCloud: Decodable {
        let cover: String
        let base: Int?
    }

    func toMetar() -> Metar {
        Metar(
            station: ICAOIdentifier(icaoId),
            raw: rawOb,
            observationTime: obsTime,
            temperatureC: temp,
            dewpointC: dewp,
            windDirectionDegrees: (wdir?.isVariable ?? false) ? nil : wdir?.numeric.map(Int.init),
            windIsVariable: wdir?.isVariable ?? false,
            windSpeedKt: wspd,
            windGustKt: wgst,
            visibilitySM: visib?.numeric,
            visibilityIsAtLeast: visib?.isAtLeast ?? false,
            altimeterHpa: altim,
            presentWeather: wxString,
            clouds: (clouds ?? []).compactMap { cloud in
                CloudCover(rawValue: cloud.cover.uppercased()).map { CloudLayer(cover: $0, baseFeetAGL: cloud.base) }
            },
            reportedCategory: fltCat.flatMap { FlightCategory(rawValue: $0.uppercased()) }
        )
    }
}

struct AWCTaf: Decodable {
    let icaoId: String
    let rawTAF: String
    let issueTime: Date?
    let validTimeFrom: Date?
    let validTimeTo: Date?

    func toTaf() -> Taf {
        Taf(
            station: ICAOIdentifier(icaoId),
            raw: rawTAF,
            issueTime: issueTime,
            validFrom: validTimeFrom,
            validTo: validTimeTo
        )
    }
}
