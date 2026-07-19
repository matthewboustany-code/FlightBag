import Foundation
import CoreGraphics
import CoreLocation
import UIKit

/// Georeferencing embedded in FAA terminal-procedure PDFs. Instrument
/// approach charts carry a geospatial viewport (`/VP` → `/BBox` +
/// `/Measure` with `/GPTS`/`/LPTS`); airport diagrams, DPs, and STARs do
/// not, so `parse` returns nil for them and the UI degrades gracefully.
nonisolated struct PlateGeoreference: Sendable, Equatable {
    /// 1-based CGPDF page index the viewport lives on.
    let pageIndex: Int
    /// The georeferenced planview region, in PDF page points (y-up).
    let pdfBBox: CGRect
    /// Geographic corners of `pdfBBox` in raster-image order:
    /// top-left, top-right, bottom-right, bottom-left.
    let corners: [CLLocationCoordinate2D]

    static func == (lhs: PlateGeoreference, rhs: PlateGeoreference) -> Bool {
        lhs.pageIndex == rhs.pageIndex && lhs.pdfBBox == rhs.pdfBBox
            && lhs.corners.map(\.latitude) == rhs.corners.map(\.latitude)
            && lhs.corners.map(\.longitude) == rhs.corners.map(\.longitude)
    }

    // MARK: Parsing

    static func parse(url: URL) -> PlateGeoreference? {
        guard let document = CGPDFDocument(url as CFURL) else { return nil }
        var best: PlateGeoreference?
        var bestArea: CGFloat = 0
        for pageIndex in 1...max(1, document.numberOfPages) {
            guard let page = document.page(at: pageIndex), let dict = page.dictionary else { continue }
            var vpArray: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(dict, "VP", &vpArray), let vpArray else { continue }
            for index in 0..<CGPDFArrayGetCount(vpArray) {
                var vpDict: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(vpArray, index, &vpDict), let vpDict,
                      let georef = parseViewport(vpDict, pageIndex: pageIndex) else { continue }
                // Several viewports can exist (planview + insets); the
                // largest is the planview.
                let area = georef.pdfBBox.width * georef.pdfBBox.height
                if area > bestArea {
                    best = georef
                    bestArea = area
                }
            }
        }
        return best
    }

    private static func parseViewport(_ viewport: CGPDFDictionaryRef, pageIndex: Int) -> PlateGeoreference? {
        guard let bboxValues = numbers(inArrayNamed: "BBox", of: viewport), bboxValues.count == 4 else { return nil }
        let bbox = CGRect(
            x: min(bboxValues[0], bboxValues[2]),
            y: min(bboxValues[1], bboxValues[3]),
            width: abs(bboxValues[2] - bboxValues[0]),
            height: abs(bboxValues[3] - bboxValues[1])
        )
        guard bbox.width > 0, bbox.height > 0 else { return nil }

        var measure: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(viewport, "Measure", &measure), let measure else { return nil }
        var subtype: UnsafePointer<Int8>?
        guard CGPDFDictionaryGetName(measure, "Subtype", &subtype), let subtype,
              String(cString: subtype) == "GEO" else { return nil }

        guard let gpts = numbers(inArrayNamed: "GPTS", of: measure), gpts.count >= 8, gpts.count % 2 == 0 else { return nil }
        // LPTS pairs the geographic points with normalized viewport points;
        // the spec default is the unit-square corners BL, TL, TR, BR.
        let lpts = numbers(inArrayNamed: "LPTS", of: measure)
            ?? [0, 0, 0, 1, 1, 1, 1, 0]
        guard lpts.count == gpts.count else { return nil }

        // FAA charts put the LPTS/GPTS registration points on an inset ring
        // (0.1…0.9), not the viewport corners, so fit an affine map
        // (u, v) → (lat, lon) over the pairs and extrapolate to the corners.
        let us = stride(from: 0, to: lpts.count, by: 2).map { lpts[$0] }
        let vs = stride(from: 1, to: lpts.count, by: 2).map { lpts[$0] }
        let lats = stride(from: 0, to: gpts.count, by: 2).map { gpts[$0] }
        let lons = stride(from: 1, to: gpts.count, by: 2).map { gpts[$0] }
        guard let latFit = affineFit(us: us, vs: vs, targets: lats),
              let lonFit = affineFit(us: us, vs: vs, targets: lons) else { return nil }

        // Raster-image corner order (v = 1 is the top of the viewport):
        // TL, TR, BR, BL.
        let corners: [CLLocationCoordinate2D] = [(0.0, 1.0), (1.0, 1.0), (1.0, 0.0), (0.0, 0.0)].map { (u, v) in
            CLLocationCoordinate2D(
                latitude: Double(latFit.0 * u + latFit.1 * v + latFit.2),
                longitude: Double(lonFit.0 * u + lonFit.1 * v + lonFit.2)
            )
        }
        guard corners.allSatisfy(CLLocationCoordinate2DIsValid) else { return nil }
        return PlateGeoreference(pageIndex: pageIndex, pdfBBox: bbox, corners: corners)
    }

    /// Least-squares fit of `target ≈ a·u + b·v + c`. Nil when the points
    /// are collinear (no unique plane).
    private static func affineFit(us: [CGFloat], vs: [CGFloat], targets: [CGFloat]) -> (CGFloat, CGFloat, CGFloat)? {
        let n = CGFloat(us.count)
        let su = us.reduce(0, +), sv = vs.reduce(0, +), st = targets.reduce(0, +)
        let suu = zip(us, us).map(*).reduce(0, +)
        let svv = zip(vs, vs).map(*).reduce(0, +)
        let suv = zip(us, vs).map(*).reduce(0, +)
        let sut = zip(us, targets).map(*).reduce(0, +)
        let svt = zip(vs, targets).map(*).reduce(0, +)
        // Normal equations, solved by Cramer's rule.
        let det = suu * (svv * n - sv * sv) - suv * (suv * n - sv * su) + su * (suv * sv - svv * su)
        guard abs(det) > 1e-9 else { return nil }
        let a = (sut * (svv * n - sv * sv) - suv * (svt * n - sv * st) + su * (svt * sv - svv * st)) / det
        let b = (suu * (svt * n - sv * st) - sut * (suv * n - su * sv) + su * (suv * st - svt * su)) / det
        let c = (suu * (svv * st - svt * sv) - suv * (suv * st - svt * su) + sut * (suv * sv - svv * su)) / det
        return (a, b, c)
    }

    private static func numbers(inArrayNamed name: String, of dict: CGPDFDictionaryRef) -> [CGFloat]? {
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dict, name, &array), let array else { return nil }
        var values: [CGFloat] = []
        for index in 0..<CGPDFArrayGetCount(array) {
            var value: CGPDFReal = 0
            guard CGPDFArrayGetNumber(array, index, &value) else { return nil }
            values.append(value)
        }
        return values
    }
}

/// Renders the georeferenced region of a plate PDF into a bitmap for the
/// map overlay.
nonisolated enum PlateRasterizer {
    /// Long side is capped: one overlay bitmap, no zoom-dependent re-render.
    static func rasterize(url: URL, georeference: PlateGeoreference, maxDimension: CGFloat = 2048) -> CGImage? {
        guard let document = CGPDFDocument(url as CFURL),
              let page = document.page(at: georeference.pageIndex),
              // FAA plates are unrotated; a rotated page would need a
              // different transform chain, so bail rather than render wrong.
              page.rotationAngle == 0 else { return nil }
        let bbox = georeference.pdfBBox
        let scale = maxDimension / max(bbox.width, bbox.height)
        let size = CGSize(width: (bbox.width * scale).rounded(), height: (bbox.height * scale).rounded())

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            // Flip to PDF's y-up space and window onto the BBox.
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: scale, y: -scale)
            cg.translateBy(x: -bbox.minX, y: -bbox.minY)
            cg.interpolationQuality = .high
            cg.drawPDFPage(page)
        }
        return image.cgImage
    }
}
