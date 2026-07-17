import Foundation
import GRDB

/// Resolves which regions a tiled chart covers by intersecting the chart's
/// bounding box (the `bounds` row GDAL writes into MBTiles metadata) with
/// per-state bounding boxes. Boxes over-approximate state shapes, which
/// matches the catalog policy: a state should list every chart that
/// meaningfully touches it. `ChartCatalog`'s hand table stays as the
/// fallback for artifacts whose bounds can't be read.
enum RegionBounds {
    struct Box {
        let minLon, minLat, maxLon, maxLat: Double

        func intersects(_ other: Box) -> Bool {
            minLon < other.maxLon && maxLon > other.minLon
                && minLat < other.maxLat && maxLat > other.minLat
        }
    }

    /// Region ids whose bounding box intersects `bounds`, sorted.
    static func regionIds(intersecting bounds: Box) -> [String] {
        stateBoxes
            .filter { $0.value.intersects(bounds) }
            .map { "US-\($0.key)" }
            .sorted()
    }

    /// The `bounds` metadata ("minLon,minLat,maxLon,maxLat") of an MBTiles
    /// file, or nil if the file isn't MBTiles or has no bounds row.
    static func mbtilesBounds(at fileURL: URL) -> Box? {
        var configuration = Configuration()
        configuration.readonly = true
        guard let queue = try? DatabaseQueue(path: fileURL.path, configuration: configuration) else { return nil }
        let value = try? queue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE name = 'bounds'")
        }
        guard let value else { return nil }
        let parts = value.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4 else { return nil }
        return Box(minLon: parts[0], minLat: parts[1], maxLon: parts[2], maxLat: parts[3])
    }

    /// Approximate state bounding boxes (degrees). Alaska is clamped to the
    /// western hemisphere — the far Aleutians past the antimeridian are
    /// covered by the Alaska charts anyway.
    static let stateBoxes: [String: Box] = [
        "AL": Box(minLon: -88.5, minLat: 30.1, maxLon: -84.9, maxLat: 35.0),
        "AK": Box(minLon: -179.5, minLat: 51.0, maxLon: -129.9, maxLat: 71.5),
        "AZ": Box(minLon: -114.9, minLat: 31.3, maxLon: -109.0, maxLat: 37.0),
        "AR": Box(minLon: -94.6, minLat: 33.0, maxLon: -89.6, maxLat: 36.5),
        "CA": Box(minLon: -124.5, minLat: 32.5, maxLon: -114.1, maxLat: 42.0),
        "CO": Box(minLon: -109.1, minLat: 36.9, maxLon: -102.0, maxLat: 41.0),
        "CT": Box(minLon: -73.8, minLat: 40.9, maxLon: -71.8, maxLat: 42.1),
        "DE": Box(minLon: -75.8, minLat: 38.4, maxLon: -74.9, maxLat: 39.9),
        "DC": Box(minLon: -77.1, minLat: 38.8, maxLon: -76.9, maxLat: 39.0),
        "FL": Box(minLon: -87.6, minLat: 24.4, maxLon: -80.0, maxLat: 31.0),
        "GA": Box(minLon: -85.6, minLat: 30.3, maxLon: -80.8, maxLat: 35.0),
        "HI": Box(minLon: -160.3, minLat: 18.9, maxLon: -154.8, maxLat: 22.3),
        "ID": Box(minLon: -117.2, minLat: 42.0, maxLon: -111.0, maxLat: 49.0),
        "IL": Box(minLon: -91.5, minLat: 36.9, maxLon: -87.0, maxLat: 42.5),
        "IN": Box(minLon: -88.1, minLat: 37.8, maxLon: -84.8, maxLat: 41.8),
        "IA": Box(minLon: -96.6, minLat: 40.4, maxLon: -90.1, maxLat: 43.5),
        "KS": Box(minLon: -102.1, minLat: 37.0, maxLon: -94.6, maxLat: 40.0),
        "KY": Box(minLon: -89.6, minLat: 36.5, maxLon: -81.9, maxLat: 39.1),
        "LA": Box(minLon: -94.0, minLat: 28.9, maxLon: -88.8, maxLat: 33.0),
        "ME": Box(minLon: -71.1, minLat: 43.0, maxLon: -66.9, maxLat: 47.5),
        "MD": Box(minLon: -79.5, minLat: 37.9, maxLon: -75.0, maxLat: 39.7),
        "MA": Box(minLon: -73.5, minLat: 41.2, maxLon: -69.9, maxLat: 42.9),
        "MI": Box(minLon: -90.4, minLat: 41.7, maxLon: -82.4, maxLat: 48.3),
        "MN": Box(minLon: -97.2, minLat: 43.5, maxLon: -89.5, maxLat: 49.4),
        "MS": Box(minLon: -91.7, minLat: 30.2, maxLon: -88.1, maxLat: 35.0),
        "MO": Box(minLon: -95.8, minLat: 36.0, maxLon: -89.1, maxLat: 40.6),
        "MT": Box(minLon: -116.1, minLat: 44.4, maxLon: -104.0, maxLat: 49.0),
        "NE": Box(minLon: -104.1, minLat: 40.0, maxLon: -95.3, maxLat: 43.0),
        "NV": Box(minLon: -120.0, minLat: 35.0, maxLon: -114.0, maxLat: 42.0),
        "NH": Box(minLon: -72.6, minLat: 42.7, maxLon: -70.6, maxLat: 45.3),
        "NJ": Box(minLon: -75.6, minLat: 38.9, maxLon: -73.9, maxLat: 41.4),
        "NM": Box(minLon: -109.1, minLat: 31.3, maxLon: -103.0, maxLat: 37.0),
        "NY": Box(minLon: -79.8, minLat: 40.5, maxLon: -71.9, maxLat: 45.0),
        "NC": Box(minLon: -84.3, minLat: 33.8, maxLon: -75.5, maxLat: 36.6),
        "ND": Box(minLon: -104.1, minLat: 45.9, maxLon: -96.6, maxLat: 49.0),
        "OH": Box(minLon: -84.8, minLat: 38.4, maxLon: -80.5, maxLat: 42.0),
        "OK": Box(minLon: -103.0, minLat: 33.6, maxLon: -94.4, maxLat: 37.0),
        "OR": Box(minLon: -124.6, minLat: 42.0, maxLon: -116.5, maxLat: 46.3),
        "PA": Box(minLon: -80.5, minLat: 39.7, maxLon: -74.7, maxLat: 42.3),
        "RI": Box(minLon: -71.9, minLat: 41.1, maxLon: -71.1, maxLat: 42.0),
        "SC": Box(minLon: -83.4, minLat: 32.0, maxLon: -78.5, maxLat: 35.2),
        "SD": Box(minLon: -104.1, minLat: 42.5, maxLon: -96.4, maxLat: 45.9),
        "TN": Box(minLon: -90.3, minLat: 35.0, maxLon: -81.6, maxLat: 36.7),
        "TX": Box(minLon: -106.6, minLat: 25.8, maxLon: -93.5, maxLat: 36.5),
        "UT": Box(minLon: -114.1, minLat: 37.0, maxLon: -109.0, maxLat: 42.0),
        "VT": Box(minLon: -73.4, minLat: 42.7, maxLon: -71.5, maxLat: 45.0),
        "VA": Box(minLon: -83.7, minLat: 36.5, maxLon: -75.2, maxLat: 39.5),
        "WA": Box(minLon: -124.8, minLat: 45.5, maxLon: -116.9, maxLat: 49.0),
        "WV": Box(minLon: -82.6, minLat: 37.2, maxLon: -77.7, maxLat: 40.6),
        "WI": Box(minLon: -92.9, minLat: 42.5, maxLon: -86.8, maxLat: 47.1),
        "WY": Box(minLon: -111.1, minLat: 41.0, maxLon: -104.1, maxLat: 45.0),
    ]
}
