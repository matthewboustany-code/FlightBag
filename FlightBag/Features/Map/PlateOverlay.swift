import MapKit
import UIKit

/// Result of off-main plate rendering, handed back to the main actor.
/// CGImage is immutable, hence the unchecked conformance.
struct PlateOverlayImage: @unchecked Sendable {
    let image: CGImage
    let corners: [CLLocationCoordinate2D]
}

/// A rasterized approach plate pinned to its real-world footprint.
/// Fully immutable after init — MapKit renders overlays on background
/// threads, so there is nothing to lock (unlike the mutable FIS-B mosaic).
final class PlateOverlay: NSObject, MKOverlay {
    let image: CGImage
    /// Geographic corners in raster order: TL, TR, BR, BL.
    let corners: [CLLocationCoordinate2D]
    let plateId: String
    let coordinate: CLLocationCoordinate2D
    let boundingMapRect: MKMapRect

    init(image: CGImage, corners: [CLLocationCoordinate2D], plateId: String) {
        self.image = image
        self.corners = corners
        self.plateId = plateId
        coordinate = CLLocationCoordinate2D(
            latitude: corners.map(\.latitude).reduce(0, +) / Double(corners.count),
            longitude: corners.map(\.longitude).reduce(0, +) / Double(corners.count)
        )
        // The quad isn't axis-aligned in Web-Mercator; the bounding rect is
        // the union of all corners.
        let points = corners.map(MKMapPoint.init)
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        boundingMapRect = MKMapRect(
            x: xs.min() ?? 0,
            y: ys.min() ?? 0,
            width: (xs.max() ?? 0) - (xs.min() ?? 0),
            height: (ys.max() ?? 0) - (ys.min() ?? 0)
        )
    }
}

/// Draws the plate bitmap through an affine transform built from three of
/// its geographic corners. The fourth corner's residual (Lambert-vs-Mercator
/// curvature over a ~0.5° chart) is negligible at plate scale — do not reuse
/// this renderer for larger georeferenced products.
final class PlateOverlayRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let overlay = overlay as? PlateOverlay, overlay.corners.count == 4 else { return }
        let topLeft = point(for: MKMapPoint(overlay.corners[0]))
        let topRight = point(for: MKMapPoint(overlay.corners[1]))
        let bottomLeft = point(for: MKMapPoint(overlay.corners[3]))
        let width = CGFloat(overlay.image.width)
        let height = CGFloat(overlay.image.height)
        guard width > 0, height > 0 else { return }

        // Image space (y-down, row 0 = top) onto the corner points.
        let transform = CGAffineTransform(
            a: (topRight.x - topLeft.x) / width,
            b: (topRight.y - topLeft.y) / width,
            c: (bottomLeft.x - topLeft.x) / height,
            d: (bottomLeft.y - topLeft.y) / height,
            tx: topLeft.x,
            ty: topLeft.y
        )

        context.saveGState()
        context.setAlpha(alpha)
        context.interpolationQuality = .high
        context.concatenate(transform)
        // CGContext draws images y-up; flip within the image rect so row 0
        // lands at the top-left corner.
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: 1, y: -1)
        context.draw(overlay.image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.restoreGState()
    }
}
