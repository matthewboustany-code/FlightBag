import MapKit
import UIKit

/// Synthesizes tiles deeper than a tile source's native maximum zoom by
/// cropping and upscaling the covering parent tile. MapKit never resamples
/// raster overlays on its own, so without this a chart goes blank exactly
/// when a pilot zooms in (Retina rendering requests one level deeper than
/// the visual zoom, making the problem bite early).
nonisolated enum TileResampler {
    /// Memoized `upscaledQuadrant`, keyed by the tile's source.
    static func cachedUpscaledQuadrant(
        source: String, parentTile data: Data, for path: MKTileOverlayPath, parent: MKTileOverlayPath
    ) -> Data? {
        let key = "\(source)|up|\(path.z)/\(path.x)/\(path.y)"
        if let hit = RenderedTileCache.data(for: key) { return hit }
        let rendered = upscaledQuadrant(parentTile: data, for: path, parent: parent)
        if let rendered { RenderedTileCache.store(rendered, for: key) }
        return rendered
    }

    /// The parent path at `nativeMaxZ` covering the requested deeper tile.
    static func parent(of path: MKTileOverlayPath, nativeMaxZ: Int) -> MKTileOverlayPath {
        let dz = path.z - nativeMaxZ
        return MKTileOverlayPath(x: path.x >> dz, y: path.y >> dz, z: nativeMaxZ, contentScaleFactor: path.contentScaleFactor)
    }

    /// Crop the requested tile's quadrant out of its parent tile image and
    /// upscale it to a full 256 px tile.
    static func upscaledQuadrant(parentTile data: Data, for path: MKTileOverlayPath, parent: MKTileOverlayPath) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let levels = path.z - parent.z
        let tileSize = CGSize(width: 256, height: 256)
        let scale = CGFloat(1 << levels)
        // Offset of this tile within the parent, in parent-tile fractions.
        let fx = CGFloat(path.x - (parent.x << levels)) / scale
        let fy = CGFloat(path.y - (parent.y << levels)) / scale

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: tileSize, format: format).pngData { _ in
            image.draw(in: CGRect(
                x: -fx * tileSize.width * scale,
                y: -fy * tileSize.height * scale,
                width: tileSize.width * scale,
                height: tileSize.height * scale
            ))
        }
    }
}

/// Tiles the app has already decoded, redrawn, and re-encoded — upscaled
/// quadrants and neatline-masked tiles. Both cost a PNG decode and encode, and
/// MapKit asks for the same tiles again on every pan back and zoom step.
nonisolated enum RenderedTileCache {
    private static let cache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = 64 << 20
        return cache
    }()

    static func data(for key: String) -> Data? {
        cache.object(forKey: key as NSString) as Data?
    }

    static func store(_ data: Data, for key: String) {
        cache.setObject(data as NSData, forKey: key as NSString, cost: data.count)
    }
}
