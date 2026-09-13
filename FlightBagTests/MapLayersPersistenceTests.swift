import Foundation
import Testing
import FBModels
@testable import FlightBag

@MainActor
@Suite struct MapLayersPersistenceTests {
    private func scratchDefaults() -> UserDefaults {
        let name = "map-layers-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func userSetFieldsSurviveARelaunch() {
        let defaults = scratchDefaults()
        let before = MapLayersState()
        before.chart = .ifrLow
        before.chartOpacity = 0.4
        before.radarEnabled = true
        before.radarSource = .adsb
        before.enabledAirspaceCategories = [Airspace.Category.allCases[0]]
        before.tfrsEnabled = false
        before.advisoryFilterAltitudeFt = 9500
        before.streamChartGaps = false
        before.save(to: defaults)

        let after = MapLayersState()
        after.load(from: defaults)
        #expect(after.snapshot == before.snapshot)
    }

    @Test func noChartIsRememberedAsNoChart() {
        let defaults = scratchDefaults()
        let before = MapLayersState()
        before.chart = nil
        before.save(to: defaults)

        let after = MapLayersState()
        #expect(after.chart != nil)  // the default
        after.load(from: defaults)
        #expect(after.chart == nil)
    }

    @Test func fieldsMissingFromAnOlderSnapshotKeepTheirDefaults() throws {
        let defaults = scratchDefaults()
        defaults.set(Data(#"{"radarEnabled":true}"#.utf8), forKey: MapLayersState.defaultsKey)
        let layers = MapLayersState()
        layers.load(from: defaults)
        #expect(layers.radarEnabled)
        #expect(layers.chart == .vfrSectional)
        #expect(layers.tfrsEnabled)
    }
}
