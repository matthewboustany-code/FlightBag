import MapKit
import UIKit
import FBFISB

/// Whole-world overlay backing the FIS-B NEXRAD mosaic. The renderer
/// draws only the blocks intersecting each requested rect, so a global
/// bounding rect costs nothing.
final class FISBRadarOverlay: NSObject, MKOverlay {
    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    let boundingMapRect = MKMapRect.world

    /// Snapshot read by the renderer on MapKit's drawing threads; swapped
    /// under a lock whenever the store changes.
    private let lock = NSLock()
    private var _mosaic = FISBRadarStore.Mosaic()

    var mosaic: FISBRadarStore.Mosaic {
        get { lock.withLock { _mosaic } }
        set { lock.withLock { _mosaic = newValue } }
    }
}

/// Draws NEXRAD intensity bins as lat/lon-aligned rectangles. CONUS goes
/// down first; regional (finer) paints over it.
final class FISBRadarRenderer: MKOverlayRenderer {
    /// Standard 8-level NEXRAD ramp. Levels 0–1 are "no precipitation"
    /// and never drawn.
    private static let intensityColors: [CGColor?] = [
        nil, nil,
        UIColor(red: 0.00, green: 0.55, blue: 0.00, alpha: 1).cgColor,  // light green
        UIColor(red: 0.00, green: 0.75, blue: 0.00, alpha: 1).cgColor,  // green
        UIColor(red: 0.20, green: 1.00, blue: 0.20, alpha: 1).cgColor,  // bright green
        UIColor(red: 1.00, green: 1.00, blue: 0.00, alpha: 1).cgColor,  // yellow
        UIColor(red: 1.00, green: 0.55, blue: 0.00, alpha: 1).cgColor,  // orange
        UIColor(red: 1.00, green: 0.00, blue: 0.00, alpha: 1).cgColor,  // red
    ]

    private var radarOverlay: FISBRadarOverlay? { overlay as? FISBRadarOverlay }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let mosaic = radarOverlay?.mosaic else { return }
        context.setAlpha(alpha)
        // CONUS first so the finer regional mosaic wins where both exist.
        drawBlocks(mosaic.conus, in: mapRect, context: context)
        drawBlocks(mosaic.regional, in: mapRect, context: context)
    }

    private func drawBlocks(
        _ blocks: [Int: FISBRadarStore.TimedBlock],
        in mapRect: MKMapRect,
        context: CGContext
    ) {
        for timed in blocks.values {
            let block = timed.block
            guard let bounds = NEXRADBlockGeometry.bounds(
                blockNumber: block.blockNumber,
                scaleFactor: block.scaleFactor
            ), Self.mapRect(for: bounds).intersects(mapRect) else { continue }

            for (index, intensity) in block.intensities.enumerated() {
                guard let color = Self.intensityColors[Int(intensity)],
                      let binBounds = NEXRADBlockGeometry.binBounds(
                        blockNumber: block.blockNumber,
                        scaleFactor: block.scaleFactor,
                        binIndex: index
                      ) else { continue }
                let binRect = Self.mapRect(for: binBounds)
                guard binRect.intersects(mapRect) else { continue }
                context.setFillColor(color)
                // Nudge outward by a hairline: adjacent bins otherwise
                // leave seams from rounding.
                context.fill(rect(for: binRect).insetBy(dx: -0.25, dy: -0.25))
            }
        }
    }

    private static func mapRect(for bounds: NEXRADBlockGeometry.Bounds) -> MKMapRect {
        let topLeft = MKMapPoint(CLLocationCoordinate2D(latitude: bounds.north, longitude: bounds.west))
        let bottomRight = MKMapPoint(CLLocationCoordinate2D(latitude: bounds.south, longitude: bounds.east))
        return MKMapRect(
            x: min(topLeft.x, bottomRight.x),
            y: min(topLeft.y, bottomRight.y),
            width: abs(bottomRight.x - topLeft.x),
            height: abs(bottomRight.y - topLeft.y)
        )
    }
}
