import Foundation
import FBModels
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Temporary Flight Restrictions with geometry.
public protocol TFRProviding: Sendable {
    func activeTFRs() async throws -> [TemporaryFlightRestriction]
}

/// TFRs from tfr.faa.gov: the list endpoint gives ids and descriptions; each
/// TFR's shapes come from its detail XML (XNOTAM format).
public struct FAATFRProvider: TFRProviding {
    private let http: any HTTPGetting
    private let baseURL: URL

    public init(http: any HTTPGetting = URLSessionHTTPClient(), baseURL: URL = URL(string: "https://tfr.faa.gov")!) {
        self.http = http
        self.baseURL = baseURL
    }

    public func activeTFRs() async throws -> [TemporaryFlightRestriction] {
        let listData = try await http.get(baseURL.appendingPathComponent("tfrapi/exportTfrList"))
        let entries = try JSONDecoder().decode([TFRListEntry].self, from: listData)

        // Details are independent; fetch a few at a time and drop failures —
        // one malformed TFR must not hide the rest.
        return await withTaskGroup(of: TemporaryFlightRestriction?.self) { group in
            var iterator = entries.makeIterator()
            var active = 0
            var results: [TemporaryFlightRestriction] = []

            func addNext() {
                guard let entry = iterator.next() else { return }
                active += 1
                group.addTask { await fetchDetail(for: entry) }
            }
            for _ in 0..<6 { addNext() }
            while active > 0 {
                guard let result = await group.next() else { break }
                active -= 1
                if let result { results.append(result) }
                addNext()
            }
            // The list endpoint has no stable order; keep output deterministic.
            return results.sorted { $0.id < $1.id }
        }
    }

    private func fetchDetail(for entry: TFRListEntry) async -> TemporaryFlightRestriction? {
        // "6/5504" → detail_6_5504.xml
        let fileId = entry.notamId.replacingOccurrences(of: "/", with: "_")
        guard let data = try? await http.get(baseURL.appendingPathComponent("download/detail_\(fileId).xml")) else {
            return nil
        }
        return Self.parseDetail(data, entry: entry)
    }

    static func parseDetail(_ data: Data, entry: TFRListEntry) -> TemporaryFlightRestriction? {
        let parser = TFRXMLParser()
        guard let parsed = parser.parse(data) else { return nil }
        let areas = parsed.areas.filter { $0.polygon.count >= 3 }
        guard !areas.isEmpty else { return nil }
        return TemporaryFlightRestriction(
            id: entry.notamId,
            type: entry.type,
            description: entry.description ?? parsed.localName ?? entry.notamId,
            effective: parsed.effective,
            expire: parsed.expire,
            areas: areas
        )
    }
}

struct TFRListEntry: Decodable, Sendable {
    let notamId: String
    let type: String?
    let description: String?

    private enum CodingKeys: String, CodingKey {
        case notamId = "notam_id"
        case type, description
    }
}

// MARK: - XNOTAM detail parsing

/// Pulls area geometry out of the XNOTAM TFR detail format. Each
/// `TFRAreaGroup` holds vertical limits (`aseTFRArea`), primitive boundaries
/// (`Abd` — polygons or circles), and usually a pre-merged final polygon
/// (`abdMergedArea`) which wins when present so primitives aren't
/// double-counted.
private final class TFRXMLParser: NSObject, XMLParserDelegate {
    struct ParsedTFR {
        var localName: String?
        var effective: Date?
        var expire: Date?
        var areas: [TemporaryFlightRestriction.Area]
    }

    private struct PendingVertex {
        var type: String?
        var lat: Double?
        var lon: Double?
        var radiusNM: Double?
    }

    private var path: [String] = []
    private var text = ""

    private var localName: String?
    private var effective: Date?
    private var expire: Date?
    private var areas: [TemporaryFlightRestriction.Area] = []

    // Current TFRAreaGroup state.
    private var groupName: String?
    private var groupFloor: String?
    private var groupFloorUnit: String?
    private var groupCeiling: String?
    private var groupCeilingUnit: String?
    private var mergedVertices: [Coordinate] = []
    private var primitiveVertices: [Coordinate] = []
    private var vertex = PendingVertex()

    func parse(_ data: Data) -> ParsedTFR? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() || !areas.isEmpty else { return nil }
        return ParsedTFR(localName: localName, effective: effective, expire: expire, areas: areas)
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        path.append(element)
        text = ""
        if element == "TFRAreaGroup" {
            groupName = nil
            groupFloor = nil
            groupFloorUnit = nil
            groupCeiling = nil
            groupCeilingUnit = nil
            mergedVertices = []
            primitiveVertices = []
        }
        if element == "Avx" {
            vertex = PendingVertex()
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        defer { path.removeLast() }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""

        // Document-level fields (direct children of Not).
        if path.suffix(2).first == "Not" {
            switch element {
            case "dateEffective": effective = Self.date(value)
            case "dateExpire": expire = Self.date(value)
            default: break
            }
        }
        if element == "txtLocalName" { localName = value }

        // Vertical limits from the group's aseTFRArea.
        if path.contains("aseTFRArea") {
            switch element {
            case "txtName": groupName = value
            case "valDistVerLower": groupFloor = value
            case "uomDistVerLower": groupFloorUnit = value
            case "valDistVerUpper": groupCeiling = value
            case "uomDistVerUpper": groupCeilingUnit = value
            default: break
            }
        }

        // Vertex fields: only direct children of Avx (Avx nests reference
        // points, e.g. Frd/DpnUid, that also carry geoLat/geoLong).
        if path.count >= 2, path[path.count - 2] == "Avx" {
            switch element {
            case "codeType": vertex.type = value
            case "geoLat": vertex.lat = Self.degrees(value)
            case "geoLong": vertex.lon = Self.degrees(value)
            case "valRadiusArc": vertex.radiusNM = Double(value)
            default: break
            }
        }

        if element == "Avx" {
            appendVertex()
        }

        if element == "TFRAreaGroup" {
            let polygon = mergedVertices.count >= 3 ? mergedVertices : primitiveVertices
            areas.append(TemporaryFlightRestriction.Area(
                name: groupName,
                floorText: format(groupFloor, unit: groupFloorUnit),
                ceilingText: format(groupCeiling, unit: groupCeilingUnit),
                polygon: polygon
            ))
        }
    }

    private func appendVertex() {
        guard let lat = vertex.lat, let lon = vertex.lon else { return }
        let inMerged = path.contains("abdMergedArea")

        if vertex.type == "CIR", let radius = vertex.radiusNM {
            let circle = Self.circle(centerLat: lat, centerLon: lon, radiusNM: radius)
            if inMerged { mergedVertices.append(contentsOf: circle) } else { primitiveVertices.append(contentsOf: circle) }
            return
        }
        // GRC (great-circle point) and arc endpoints; arcs render as chords.
        let coordinate = Coordinate(latitude: lat, longitude: lon)
        if inMerged { mergedVertices.append(coordinate) } else { primitiveVertices.append(coordinate) }
    }

    private func format(_ value: String?, unit: String?) -> String? {
        guard let value else { return nil }
        return unit.map { "\(value) \($0)" } ?? value
    }

    /// "30.32249911N" / "097.71666667W" → signed decimal degrees.
    static func degrees(_ raw: String) -> Double? {
        guard let hemisphere = raw.last else { return nil }
        let magnitude = Double(raw.dropLast())
        let sign: Double? = switch hemisphere {
        case "N", "E": 1
        case "S", "W": -1
        default: nil
        }
        guard let magnitude, let sign else { return Double(raw) }
        return sign * magnitude
    }

    private static func date(_ raw: String) -> Date? {
        try? Date(raw, strategy: Date.ISO8601FormatStyle(timeZone: TimeZone(identifier: "UTC")!))
    }

    /// Approximate a radius circle as a 64-gon.
    static func circle(centerLat: Double, centerLon: Double, radiusNM: Double, segments: Int = 64) -> [Coordinate] {
        let earthRadiusNM = 3440.065
        let angular = radiusNM / earthRadiusNM
        let lat = centerLat * .pi / 180
        let lon = centerLon * .pi / 180
        return (0...segments).map { i in
            let bearing = 2 * .pi * Double(i) / Double(segments)
            let pointLat = asin(sin(lat) * cos(angular) + cos(lat) * sin(angular) * cos(bearing))
            let pointLon = lon + atan2(
                sin(bearing) * sin(angular) * cos(lat),
                cos(angular) - sin(lat) * sin(pointLat)
            )
            return Coordinate(latitude: pointLat * 180 / .pi, longitude: pointLon * 180 / .pi)
        }
    }
}
