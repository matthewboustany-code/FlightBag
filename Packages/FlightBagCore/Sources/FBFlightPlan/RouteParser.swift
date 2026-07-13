import Foundation
import FBModels

/// Resolves route-string identifiers against a navigation database.
/// The app implements this with the GRDB aviation database; the server with
/// its own copy; tests with an in-memory dictionary.
public protocol WaypointResolving: Sendable {
    func resolveWaypoint(identifier: String) async throws -> ResolvedWaypoint?
    /// True when the identifier is a published airway (e.g. "V163", "J24", "Q22", "T254").
    func isAirway(identifier: String) async throws -> Bool
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
        /// Airway identifier; expansion into fixes happens against the airway
        /// database (Phase 3).
        case airway(String)
        case direct
        case unresolved(String)
    }

    public var elements: [Element]

    public var waypoints: [ResolvedWaypoint] {
        elements.compactMap {
            if case .waypoint(let wp) = $0 { return wp }
            return nil
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
                elements.append(.airway(token))
                continue
            }
            if let waypoint = try await resolver.resolveWaypoint(identifier: token) {
                elements.append(.waypoint(waypoint))
            } else {
                elements.append(.unresolved(token))
            }
        }
        return ParsedRoute(elements: elements)
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
