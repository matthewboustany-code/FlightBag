import Testing
import FBModels
@testable import FlightBag

@Suite struct FrequencyDisplayTests {
    @Test func mixedBandGroupKeepsBothVHFFirst() {
        // Airport 02A's real published pair: APP/DEP on 121.2 VHF and 269.05 UHF.
        let groups = FrequencyDisplay.grouped([
            Frequency(use: "APP/DEP", kHz: 269_050),
            Frequency(use: "APP/DEP", kHz: 121_200),
        ])
        #expect(groups.count == 1)
        #expect(groups[0].values == ["121.200", "269.050"])
    }

    @Test func uhfOnlyGroupStillShows() {
        let groups = FrequencyDisplay.grouped([Frequency(use: "TWR", kHz: 279_250)])
        #expect(groups[0].values == ["279.250"])
    }

    @Test func groupsFollowPilotOrder() {
        let groups = FrequencyDisplay.grouped([
            Frequency(use: "TWR", kHz: 118_000),
            Frequency(use: "ATIS", kHz: 124_400),
            Frequency(use: "UNICOM", kHz: 122_950),
        ])
        #expect(groups.map(\.use) == ["ATIS", "TWR", "UNICOM"])
    }
}
