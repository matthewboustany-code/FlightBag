import MapKit
import UIKit

/// Streams FAA chart tiles and keeps the chart visible past the service's
/// deepest published zoom by cropping and upscaling parent tiles — MapKit
/// never resamples rasters on its own, so without this a chart goes blank
/// exactly when a pilot zooms in (worst on IFR High, which stops at z9
/// while Retina rendering requests z+1).
final class StreamingChartOverlay: MKTileOverlay {
    private let nativeMaxZ: Int

    init(kind: ChartKind) {
        nativeMaxZ = kind.streamingZoomRange.upperBound
        super.init(urlTemplate: kind.streamingURLTemplate)
        canReplaceMapContent = false
        minimumZ = kind.streamingZoomRange.lowerBound
        // No maximumZ: deeper levels are synthesized from nativeMaxZ tiles.
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
