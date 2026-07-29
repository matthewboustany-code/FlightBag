import Foundation
import Testing
import FBModels
@testable import FlightBag

@MainActor
@Suite struct NotamOverlayTests {
    private func notam(
        id: String = "01/005",
        radiusNM: Double? = 5,
        coordinate: Coordinate? = Coordinate(latitude: 30.19, longitude: -97.67),
        effectiveEnd: Date? = nil,
        endIsEstimated: Bool = true
    ) -> Notam {
        Notam(
            id: id,
            location: ICAOIdentifier("KAUS"),
            text: "TWY A CLSD",
            effectiveEnd: effectiveEnd,
            endIsEstimated: endIsEstimated,
            coordinate: coordinate,
            radiusNM: radiusNM
        )
    }

    private func layers(notamsEnabled: Bool = true) -> MapLayersState {
        let layers = MapLayersState()
        layers.notamsEnabled = notamsEnabled
        layers.tfrsEnabled = false
        return layers
    }

    @Test func onlyNotamsWithCentreAndRadiusDraw() {
        let store = AdvisoryStore()
        let candidates = [
            notam(id: "01/001"),
            notam(id: "01/002", radiusNM: nil),
            notam(id: "01/003", coordinate: nil),
            notam(id: "01/004", radiusNM: 0),
        ]
        let visible = AdvisoryOverlayBuilder.visibleNotams(
            layers: layers(), notams: candidates, store: store
        )
        #expect(visible.map(\.id) == ["01/001"])
    }

    @Test func expiredNotamsDoNotDraw() {
        let store = AdvisoryStore()
        let expired = notam(
            id: "01/009",
            effectiveEnd: Date(timeIntervalSince1970: 1_000),
            endIsEstimated: false
        )
        let visible = AdvisoryOverlayBuilder.visibleNotams(
            layers: layers(), notams: [expired], store: store
        )
        #expect(visible.isEmpty)
    }

    @Test func theSameNotamFromTwoAirportsDrawsOnce() {
        let store = AdvisoryStore()
        let visible = AdvisoryOverlayBuilder.visibleNotams(
            layers: layers(), notams: [notam(), notam()], store: store
        )
        #expect(visible.count == 1)
    }

    @Test func disabledLayerProducesNoOverlays() {
        let store = AdvisoryStore()
        let overlays = AdvisoryOverlayBuilder.overlays(
            layers: layers(notamsEnabled: false), store: store, notams: [notam()]
        )
        #expect(overlays.isEmpty)
    }

    @Test func enabledLayerProducesOneTappablePolygon() throws {
        let store = AdvisoryStore()
        let overlays = AdvisoryOverlayBuilder.overlays(
            layers: layers(), store: store, notams: [notam()]
        )
        #expect(overlays.count == 1)
        let info = try #require(overlays.first?.info)
        #expect(info.title.contains("01/005"))
        #expect(info.title.contains("KAUS"))
        #expect(info.detail == "TWY A CLSD")
    }

    @Test func circlePolygonIsClosedRoundAndCorrectlySized() {
        let centre = Coordinate(latitude: 30.0, longitude: -97.0)
        let ring = AdvisoryOverlayBuilder.circlePolygon(centre: centre, radiusNM: 10)
        #expect(ring.count == 48)

        // Every vertex should sit ~10 NM from the centre. Longitude degrees
        // are compressed by cos(latitude); if that scaling were missing the
        // east/west vertices would come out ~13% short here.
        let scale = cos(centre.latitude * .pi / 180)
        for point in ring {
            let dLat = point.latitude - centre.latitude
            let dLon = (point.longitude - centre.longitude) * scale
            let distanceNM = sqrt(dLat * dLat + dLon * dLon) * 60
            #expect(abs(distanceNM - 10) < 0.05)
        }
    }

    @Test func circleStaysRoundAtHighLatitude() {
        // At 70°N a naive circle is nearly three times too wide.
        let centre = Coordinate(latitude: 70.0, longitude: 20.0)
        let ring = AdvisoryOverlayBuilder.circlePolygon(centre: centre, radiusNM: 5)
        let scale = cos(centre.latitude * .pi / 180)
        for point in ring {
            let dLat = point.latitude - centre.latitude
            let dLon = (point.longitude - centre.longitude) * scale
            let distanceNM = sqrt(dLat * dLat + dLon * dLon) * 60
            #expect(abs(distanceNM - 5) < 0.05)
        }
    }
}
