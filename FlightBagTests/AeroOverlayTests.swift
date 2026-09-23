import Foundation
import Testing
import FBModels
@testable import FlightBag

@Suite struct WaypointThinningTests {
    private func fix(_ id: String, _ lat: Double, _ lon: Double) -> AeroDatabase.MapWaypoint {
        .init(identifier: id, name: nil, kind: .fix, latitude: lat, longitude: lon)
    }

    /// A 20×20 lattice over a 1° box, listed south-to-north the way the
    /// (lat, lon) index returns rows.
    private func lattice() -> [AeroDatabase.MapWaypoint] {
        (0..<20).flatMap { row in
            (0..<20).map { col in
                fix(String(format: "F%02d%02d", row, col), 30 + Double(row) / 20, -98 + Double(col) / 20)
            }
        }
    }

    @Test func underTheCapIsUntouched() {
        let points = Array(lattice().prefix(50))
        #expect(WaypointThinning.spread(points, span: 1, maxCount: 100) == points)
    }

    @Test func coversTheWholeBoxNotJustTheSouthernEdge() {
        let thinned = WaypointThinning.spread(lattice(), span: 1, maxCount: 100)
        #expect(thinned.count == 100)
        // A plain prefix(100) would stop at 30.2°N.
        #expect(thinned.contains { $0.latitude >= 30.9 })
        #expect(thinned.contains { $0.latitude < 30.1 })
    }

    @Test func navaidsWinTheirCell() {
        var points = lattice()
        let vor = AeroDatabase.MapWaypoint(identifier: "ZZZ", name: nil, kind: .navaid(type: "VORTAC"), latitude: 30.51, longitude: -97.49)
        points.append(vor)
        let thinned = WaypointThinning.spread(points, span: 1, maxCount: 100)
        #expect(thinned.contains(vor))
    }

    @Test func isStableAcrossCalls() {
        let a = WaypointThinning.spread(lattice(), span: 1, maxCount: 60)
        let b = WaypointThinning.spread(lattice().reversed(), span: 1, maxCount: 60)
        #expect(Set(a) == Set(b))
    }
}

@Suite struct AirwayLabelPlacementTests {
    @Test func picksTheOnScreenSegmentNearestCentre() throws {
        // A long east-west airway; only the middle segments are in view.
        let line = stride(from: -100.0, through: -94.0, by: 1.0).map { Coordinate(latitude: 30.5, longitude: $0) }
        let anchor = AirwayLabelPlacement.anchor(for: line, minLat: 30, maxLat: 31, minLon: -98.2, maxLon: -96.2)
        let longitude = try #require(anchor?.longitude)
        #expect(longitude == -97.5 || longitude == -96.5)
    }

    @Test func offScreenLineHasNoAnchor() {
        let line = [Coordinate(latitude: 40, longitude: -80), Coordinate(latitude: 41, longitude: -79)]
        #expect(AirwayLabelPlacement.anchor(for: line, minLat: 30, maxLat: 31, minLon: -98, maxLon: -97) == nil)
    }
}
