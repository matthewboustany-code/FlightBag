import MapKit
import UIKit
import FBModels

/// Streams chart tiles from whichever authority's service a `ChartSource`
/// names, and keeps the chart visible past that service's deepest published
/// zoom by cropping and upscaling parent tiles — MapKit never resamples
/// rasters on its own, so without this a chart goes blank exactly when a pilot
/// zooms in (worst on IFR High, which stops at z9 while Retina rendering
/// requests z+1).
final class StreamingChartOverlay: MKTileOverlay {
    private let nativeMaxZ: Int
    /// Kept so the map can credit the source — several licences require it.
    let source: ChartSource

    init(source: ChartSource, streaming: ChartSource.Streaming) {
        self.source = source
        nativeMaxZ = streaming.zoomRange.upperBound
        super.init(urlTemplate: streaming.urlTemplate)
        canReplaceMapContent = false
        minimumZ = streaming.zoomRange.lowerBound
        // No maximumZ: deeper levels are synthesized from nativeMaxZ tiles.
    }

    /// Convenience for the common path: resolve the best source for a chart
    /// kind, or nil when nothing streams it (open flightmaps, for one, ships
    /// MBTiles and runs no tile service).
    convenience init?(
        kind: ChartKind,
        regionIds: Set<String> = [],
        manifestSources: [ChartSource] = []
    ) {
        guard let source = ChartSource.streamingSource(
            for: kind.contentKind,
            regionIds: regionIds,
            manifestSources: manifestSources
        ), let streaming = source.streaming else { return nil }
        self.init(source: source, streaming: streaming)
    }

    nonisolated override func loadTile(at path: MKTileOverlayPath, result: @escaping @Sendable (Data?, (any Error)?) -> Void) {
        guard path.z > nativeMaxZ else {
            super.loadTile(at: path, result: result)
            return
        }

        let parent = TileResampler.parent(of: path, nativeMaxZ: nativeMaxZ)
        super.loadTile(at: parent) { data, error in
            guard let data else {
                result(nil, error)
                return
            }
            result(TileResampler.upscaledQuadrant(parentTile: data, for: path, parent: parent), nil)
        }
    }
}
