import Foundation
import Observation
import FBFISB

/// NEXRAD mosaic assembled from FIS-B uplink blocks. Regional blocks are
/// higher resolution and draw over CONUS.
@MainActor
@Observable
final class FISBRadarStore {
    /// An immutable snapshot handed to the renderer, which draws off the
    /// main thread.
    nonisolated struct Mosaic: Sendable {
        var regional: [Int: TimedBlock] = [:]
        var conus: [Int: TimedBlock] = [:]

        var isEmpty: Bool { regional.isEmpty && conus.isEmpty }
    }

    struct TimedBlock: Sendable {
        let block: NEXRADBlock
        let receivedAt: Date
    }

    private(set) var mosaic = Mosaic()
    private(set) var updatedAt: Date?
    /// Bumped whenever the mosaic changes, so the map knows to redraw.
    private(set) var dataVersion = 0

    /// FIS-B repeats the full CONUS picture every ~15 min and regional
    /// every ~2.5 min; anything older than this is stale weather.
    private static let expireAfterSeconds: TimeInterval = 600

    func ingest(_ product: NEXRADProduct, now: Date = Date()) {
        var mosaic = self.mosaic
        var changed = false
        for block in product.blocks {
            let timed = TimedBlock(block: block, receivedAt: now)
            switch product.scope {
            case .regional: mosaic.regional[block.blockNumber] = timed
            case .conus: mosaic.conus[block.blockNumber] = timed
            }
            changed = true
        }
        for blockNumber in product.clearedBlocks {
            switch product.scope {
            case .regional: changed = mosaic.regional.removeValue(forKey: blockNumber) != nil || changed
            case .conus: changed = mosaic.conus.removeValue(forKey: blockNumber) != nil || changed
            }
        }
        guard changed else { return }
        self.mosaic = mosaic
        updatedAt = now
        dataVersion += 1
    }

    /// Drop blocks older than the expiry window. Call on the 1 Hz tick.
    func expire(now: Date = Date()) {
        var mosaic = self.mosaic
        let cutoff = now.addingTimeInterval(-Self.expireAfterSeconds)
        let regionalCount = mosaic.regional.count
        let conusCount = mosaic.conus.count
        mosaic.regional = mosaic.regional.filter { $0.value.receivedAt > cutoff }
        mosaic.conus = mosaic.conus.filter { $0.value.receivedAt > cutoff }
        guard mosaic.regional.count != regionalCount || mosaic.conus.count != conusCount else { return }
        self.mosaic = mosaic
        dataVersion += 1
    }

    func clear() {
        guard !mosaic.isEmpty else { return }
        mosaic = Mosaic()
        updatedAt = nil
        dataVersion += 1
    }
}
