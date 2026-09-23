import Foundation
import MapKit
import Testing
import FBModels
@testable import FlightBag

@Suite struct AeroDatabaseCycleSelectionTests {
    private func cyclesRoot(with dirs: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cycles-\(UUID().uuidString)", isDirectory: true)
        for dir in dirs {
            let url = root.appendingPathComponent(dir, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data().write(to: url.appendingPathComponent("aero.sqlite"))
        }
        return root
    }

    @Test func seedDirectoryDoesNotOutrankRealCycles() throws {
        // "seed" sorts after every digit string, so a string sort picked it.
        let root = try cyclesRoot(with: ["2608", "2609", "seed"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(AeroDatabase.newestInstalledCycle(in: root)?.id == "2609")
    }

    @Test func ignoresCycleDirectoriesWithoutADatabase() throws {
        let root = try cyclesRoot(with: ["2608"])
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("2610", isDirectory: true), withIntermediateDirectories: true)
        #expect(AeroDatabase.newestInstalledCycle(in: root)?.id == "2608")
    }

    @Test func aDatabaseDownloadedAheadWaitsForItsCycle() throws {
        let root = try cyclesRoot(with: ["2610", "2611"])
        defer { try? FileManager.default.removeItem(at: root) }
        let beforeFlip = DataCycle(id: "2611")!.effectiveDate.addingTimeInterval(-60)
        #expect(AeroDatabase.newestInstalledCycle(in: root, now: beforeFlip)?.id == "2610")
        #expect(AeroDatabase.newestInstalledCycle(in: root, now: beforeFlip.addingTimeInterval(120))?.id == "2611")
    }

    @Test func noParseableCycleMeansNone() throws {
        let root = try cyclesRoot(with: ["seed", "junk"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(AeroDatabase.newestInstalledCycle(in: root) == nil)
    }
}

@MainActor
@Suite struct MapDemoSpanTests {
    @Test func oversizedSpanClampsToAValidRegion() {
        let span = EFBMapView.demoSpan(200)
        #expect(span.latitudeDelta <= 180)
        #expect(span.longitudeDelta <= 360)
        #expect(EFBMapView.demoSpan(2.2).latitudeDelta == 2.2)
    }
}
