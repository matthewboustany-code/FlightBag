import Foundation
import Testing
import FBModels
@testable import FlightBag

@Suite struct ChartKindTests {
    private func tempTiles() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chartkind-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func manifestKindWinsOverTheFilename() throws {
        let dir = tempTiles()
        defer { try? FileManager.default.removeItem(at: dir) }

        // A name the substring matcher gets wrong: "Highlands" contains "high".
        let url = dir.appendingPathComponent("Scottish_Highlands_ofm.mbtiles")
        try Data().write(to: url)
        #expect(ChartKind.kind(forFileName: url.lastPathComponent) == .ifrHigh)

        try Data("vfrSectional".utf8).write(to: url.appendingPathExtension("kind"))
        #expect(ChartStore.kind(for: url, fileName: url.lastPathComponent) == .vfrSectional)
    }

    @Test func fallsBackToFilenameWithoutASidecar() throws {
        let dir = tempTiles()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("San_Antonio_sectional.mbtiles")
        try Data().write(to: url)
        // Sideloaded charts have no manifest entry, so inference still applies.
        #expect(ChartStore.kind(for: url, fileName: url.lastPathComponent) == .vfrSectional)
    }

    @Test func corruptSidecarFallsBackRatherThanFailing() throws {
        let dir = tempTiles()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("ENR_L15_ifr_low.mbtiles")
        try Data().write(to: url)
        try Data("not-a-content-kind".utf8).write(to: url.appendingPathExtension("kind"))
        #expect(ChartStore.kind(for: url, fileName: url.lastPathComponent) == .ifrLow)
    }

    @Test func nonChartContentKindsDoNotMapToAChartKind() {
        #expect(ChartKind(contentKind: .vfrSectional) == .vfrSectional)
        #expect(ChartKind(contentKind: .ifrEnrouteLow) == .ifrLow)
        #expect(ChartKind(contentKind: .ifrEnrouteHigh) == .ifrHigh)
        #expect(ChartKind(contentKind: .basemap) == nil)
        #expect(ChartKind(contentKind: .plates) == nil)
        #expect(ChartKind(contentKind: .aeroDatabase) == nil)
    }
}
