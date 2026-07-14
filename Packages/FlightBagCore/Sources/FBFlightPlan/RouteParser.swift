import Foundation
import FBModels

/// Resolves route-string identifiers against a navigation database.
/// The app implements this with the GRDB aviation database; the server with
/// its own copy; tests with an in-memory dictionary.
public protocol WaypointResolving: Sendable {
    func resolveWaypoint(identifier: String) async throws -> ResolvedWaypoint?
    /// True when the identifier is a published airway (e.g. "V163", "J24", "Q22", "T254").
    func isAirway(identifier: String) async throws -> Bool
    /// The airway's full ordered point list, empty when unknown. Resolvers
    /// without airway data inherit the default empty implementation.
    func airwayPoints(identifier: String) async throws -> [ResolvedWaypoint]
}

extension WaypointResolving {
    public func airwayPoints(identifier: String) async throws -> [ResolvedWaypoint] { [] }
}

public struct ResolvedWaypoint: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case airport, navaid, fix, latLon
    }

    public var identifier: String
    public var name: String?
    public var coordinate: Coordinate
    public var kind: Kind

    public init(identifier: String, name: String? = nil, coordinate: Coordinate, kind: Kind) {
        self.identifier = identifier
        self.name = name
        self.coordinate = coordinate
        self.kind = kind
    }
}

public struct ParsedRoute: Sendable, Hashable {
    public enum Element: Sendable, Hashable {
        case waypoint(ResolvedWaypoint)
        /// An airway with the intermediate points between its entry and exit
        /// waypoints. `via` is empty when the bracketing waypoints don't both
        /// sit on the airway (or no airway data is available) — the UI flags
        /// that instead of guessing.
        case airway(String, via: [ResolvedWaypoint])
        case direct
        case unresolved(String)
    }

    public var elements: [Element]

    /// The flown waypoint sequence: explicit waypoints plus airway
    /// intermediates, in route order.
    public var waypoints: [ResolvedWaypoint] {
        elements.flatMap { element -> [ResolvedWaypoint] in
            switch element {
            case .waypoint(let wp): return [wp]
            case .airway(_, let via): return via
            case .direct, .unresolved: return []
            }
        }
    }

    public var unresolvedIdentifiers: [String] {
        elements.compactMap {
            if case .unresolved(let ident) = $0 { return ident }
            return nil
        }
    }

    /// Total great-circle distance across resolved waypoints, NM.
    public var distanceNM: Double {
        let wps = waypoints
        guard wps.count >= 2 else { return 0 }
        return zip(wps, wps.dropFirst()).reduce(0) { total, pair in
            total + NavMath.distanceNM(from: pair.0.coordinate, to: pair.1.coordinate)
        }
    }
}

public struct RouteParser: Sendable {
    private let resolver: any WaypointResolving

    public init(resolver: any WaypointResolving) {
        self.resolver = resolver
    }

    /// Parse a route string like "KAUS CWK V163 LOA DCT KDAL". Departure and
    /// destination may be included or omitted; tokens that resolve to nothing
    /// come back as `.unresolved` so the UI can flag them.
    public func parse(_ route: String) async throws -> ParsedRoute {
        var elements: [ParsedRoute.Element] = []
        let tokens = route.uppercased().split(separator: " ").map(String.init)

        for token in tokens {
            if token == "DCT" {
                elements.append(.direct)
                continue
            }
            if let latLon = Self.parseLatLon(token) {
                elements.append(.waypoint(ResolvedWaypoint(identifier: token, coordinate: latLon, kind: .latLon)))
                continue
            }
            if try await resolver.isAirway(identifier: token) {
                elements.append(.airway(token, via: []))
                continue
            }
            if let waypoint = try await resolver.resolveWaypoint(identifier: token) {
                elements.append(.waypoint(waypoint))
            } else {
                elements.append(.unresolved(token))
            }
        }
        return ParsedRoute(elements: try await expandAirways(elements))
    }

    /// Fill each airway's `via` with the points between its bracketing entry
    /// and exit waypoints, honoring airway direction (reversed when flown
    /// exit-to-entry).
    private func expandAirways(_ elements: [ParsedRoute.Element]) async throws -> [ParsedRoute.Element] {
        var result = elements
        for index in result.indices {
            guard case .airway(let ident, _) = result[index] else { continue }

            func bracketingWaypoint(searching indices: some Sequence<Int>) -> ResolvedWaypoint? {
                for i in indices {
                    if case .waypoint(let wp) = result[i] { return wp }
                    if case .airway = result[i] { return nil }
                    if case .unresolved = result[i] { return nil }
                }
                return nil
            }
            guard let entry = bracketingWaypoint(searching: (0..<index).reversed()),
                  let exit = bracketingWaypoint(searching: (index + 1)..<result.count) else { continue }

            let points = try await resolver.airwayPoints(identifier: ident)
            guard let entryIndex = points.firstIndex(where: { $0.identifier == entry.identifier }),
                  let exitIndex = points.firstIndex(where: { $0.identifier == exit.identifier }),
                  entryIndex != exitIndex else { continue }

            let via: [ResolvedWaypoint]
            if entryIndex < exitIndex {
                via = Array(points[(entryIndex + 1)..<exitIndex])
            } else {
                via = Array(points[(exitIndex + 1)..<entryIndex]).reversed()
            }
            result[index] = .airway(ident, via: via)
        }
        return result
    }

    /// ICAO lat/lon waypoints: "4620N07805W" (degrees+minutes) or "46N078W" (whole degrees).
    static func parseLatLon(_ token: String) -> Coordinate? {
        if let match = token.range(of: "^([0-9]{2})([0-9]{2})?(N|S)([0-9]{3})([0-9]{2})?(E|W)$", options: .regularExpression),
           match == token.startIndex..<token.endIndex {
            let scanner = token
            // Split via regex captures the manual way to stay Foundation-only.
            let ns = scanner.contains("N") ? "N" : "S"
            let ew = scanner.contains("E") ? "E" : "W"
            let parts = scanner.split(whereSeparator: { $0 == Character(ns) || $0 == Character(ew) }).map(String.init)
            guard parts.count == 2 else { return nil }
            func value(_ digits: String, isLongitude: Bool) -> Double? {
                let degreeCount = isLongitude ? 3 : 2
                if digits.count == degreeCount {
                    return Double(digits)
                }
                if digits.count == degreeCount + 2,
                   let deg = Double(digits.prefix(degreeCount)),
                   let minutes = Double(digits.suffix(2)), minutes < 60 {
                    return deg + minutes / 60
                }
                return nil
            }
            guard let lat = value(parts[0], isLongitude: false),
                  let lon = value(parts[1], isLongitude: true),
                  lat <= 90, lon <= 180 else { return nil }
            return Coordinate(
                latitude: ns == "N" ? lat : -lat,
                longitude: ew == "E" ? lon : -lon
            )
        }
        return nil
    }
}
