import Foundation
import CoreGraphics
import CoreLocation
import FBModels

/// Georeferences military (DoD-produced) approach plates, which — unlike
/// FAA civil IAPs — carry no embedded geospatial viewport. The planview's
/// RNAV waypoint symbols (4-point stars) are detected in the PDF's vector
/// content and registered against surveyed fix/navaid/runway-end
/// coordinates by a north-up-constrained similarity fit with unknown
/// correspondence (RANSAC over star-pair/fix-pair hypotheses). Any doubt →
/// nil, and the UI degrades exactly as it does today (no overlay).
///
/// Only plates that draw RNAV stars can match (RNAV/GPS approaches); TACAN
/// and ILS charts have no star symbols and correctly return nil. Decorative
/// stars (TAA insets, MSA circles) are rejected as fit outliers.
///
/// Stages are `internal` so unit tests can exercise them individually.
nonisolated enum ApproachFixGeoreference {
    /// Bump to invalidate PlateGeoreferenceResolver's cached results after
    /// algorithm changes.
    static let matcherVersion = 1

    /// A surveyed point a planview star may represent.
    struct Candidate {
        let identifier: String
        let latitude: Double
        let longitude: Double
    }

    // Tuning. Planview scales run ~100–400 m/pt (TAA plates must fit 30 NM
    // rings); star detection is good to about a point, so match tolerance
    // and the accept gate are expressed in page points times scale.
    static let scaleRange: ClosedRange<Double> = 40...500
    static let maxRotationDegrees = 1.5
    static let minInliers = 5
    static let rmsGatePagePoints = 1.0

    // MARK: Entry point

    static func match(url: URL, candidates: [Candidate]) -> PlateGeoreference? {
        guard candidates.count >= minInliers else { return nil }
        guard let document = CGPDFDocument(url as CFURL),
              let page = document.page(at: 1),
              page.rotationAngle == 0 else { return nil }
        let stars = starCenters(in: filledPolygons(of: page))
        guard stars.count >= minInliers else { return nil }
        guard let fit = register(stars: stars, candidates: candidates) else { return nil }

        // Georeference only the region the inliers vouch for: their
        // bounding box plus a margin, clamped to the page. Scale breaks and
        // not-to-scale insets outside it are never claimed.
        let xs = fit.inlierPagePoints.map(\.x), ys = fit.inlierPagePoints.map(\.y)
        let cropBox = page.getBoxRect(.cropBox)
        let bbox = CGRect(
            x: xs.min()! - 30, y: ys.min()! - 30,
            width: (xs.max()! - xs.min()!) + 60, height: (ys.max()! - ys.min()!) + 60
        ).intersection(cropBox)
        guard bbox.width > 60, bbox.height > 60 else { return nil }

        let corners = [
            CGPoint(x: bbox.minX, y: bbox.maxY),
            CGPoint(x: bbox.maxX, y: bbox.maxY),
            CGPoint(x: bbox.maxX, y: bbox.minY),
            CGPoint(x: bbox.minX, y: bbox.minY),
        ].map { fit.projection.coordinate(fromMeters: fit.transform.apply($0)) }
        guard corners.allSatisfy(CLLocationCoordinate2DIsValid) else { return nil }
        return PlateGeoreference(pageIndex: 1, pdfBBox: bbox, corners: corners)
    }

    // MARK: PDF vector extraction

    /// Filled subpath polygons in page space (y-up). Same scanner pattern
    /// as AirportDiagramGeoreference, but kept self-contained: this
    /// harvest keeps every vertex count (star symbols run 20+ vertices).
    static func filledPolygons(of page: CGPDFPage) -> [[CGPoint]] {
        let state = ScanState()
        let table = CGPDFOperatorTableCreate()!

        func register(_ name: String, _ callback: @convention(c) (CGPDFScannerRef, UnsafeMutableRawPointer?) -> Void) {
            CGPDFOperatorTableSetCallback(table, name, callback)
        }

        register("q") { _, info in ScanState.from(info).pushCTM() }
        register("Q") { _, info in ScanState.from(info).popCTM() }
        register("cm") { scanner, info in
            var values = [CGPDFReal](repeating: 0, count: 6)
            for index in stride(from: 5, through: 0, by: -1) {
                CGPDFScannerPopNumber(scanner, &values[index])
            }
            ScanState.from(info).concatenate(CGAffineTransform(
                a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5]
            ))
        }
        register("m") { scanner, info in
            var y: CGPDFReal = 0, x: CGPDFReal = 0
            CGPDFScannerPopNumber(scanner, &y)
            CGPDFScannerPopNumber(scanner, &x)
            ScanState.from(info).moveTo(CGPoint(x: x, y: y))
        }
        register("l") { scanner, info in
            var y: CGPDFReal = 0, x: CGPDFReal = 0
            CGPDFScannerPopNumber(scanner, &y)
            CGPDFScannerPopNumber(scanner, &x)
            ScanState.from(info).lineTo(CGPoint(x: x, y: y))
        }
        register("c") { scanner, info in
            var values = [CGPDFReal](repeating: 0, count: 6)
            for index in stride(from: 5, through: 0, by: -1) {
                CGPDFScannerPopNumber(scanner, &values[index])
            }
            let state = ScanState.from(info)
            state.lineTo(CGPoint(x: values[0], y: values[1]))
            state.lineTo(CGPoint(x: values[2], y: values[3]))
            state.lineTo(CGPoint(x: values[4], y: values[5]))
        }
        register("v") { scanner, info in
            var values = [CGPDFReal](repeating: 0, count: 4)
            for index in stride(from: 3, through: 0, by: -1) {
                CGPDFScannerPopNumber(scanner, &values[index])
            }
            let state = ScanState.from(info)
            state.lineTo(CGPoint(x: values[0], y: values[1]))
            state.lineTo(CGPoint(x: values[2], y: values[3]))
        }
        register("y") { scanner, info in
            var values = [CGPDFReal](repeating: 0, count: 4)
            for index in stride(from: 3, through: 0, by: -1) {
                CGPDFScannerPopNumber(scanner, &values[index])
            }
            let state = ScanState.from(info)
            state.lineTo(CGPoint(x: values[0], y: values[1]))
            state.lineTo(CGPoint(x: values[2], y: values[3]))
        }
        register("re") { scanner, info in
            var h: CGPDFReal = 0, w: CGPDFReal = 0, y: CGPDFReal = 0, x: CGPDFReal = 0
            CGPDFScannerPopNumber(scanner, &h)
            CGPDFScannerPopNumber(scanner, &w)
            CGPDFScannerPopNumber(scanner, &y)
            CGPDFScannerPopNumber(scanner, &x)
            ScanState.from(info).rectangle(CGRect(x: x, y: y, width: w, height: h))
        }
        register("h") { _, info in ScanState.from(info).closeSubpath() }
        register("f") { _, info in ScanState.from(info).fill() }
        register("f*") { _, info in ScanState.from(info).fill() }
        register("B") { _, info in ScanState.from(info).fill() }
        register("B*") { _, info in ScanState.from(info).fill() }
        register("S") { _, info in ScanState.from(info).discardPath() }
        register("n") { _, info in ScanState.from(info).discardPath() }

        let stream = CGPDFContentStreamCreateWithPage(page)
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(state).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(stream)
        CGPDFOperatorTableRelease(table)
        return state.filledPolygons
    }

    final class ScanState {
        var ctm = CGAffineTransform.identity
        private var ctmStack: [CGAffineTransform] = []
        private var currentSubpath: [CGPoint] = []
        private var subpaths: [[CGPoint]] = []
        var filledPolygons: [[CGPoint]] = []

        static func from(_ info: UnsafeMutableRawPointer?) -> ScanState {
            Unmanaged<ScanState>.fromOpaque(info!).takeUnretainedValue()
        }

        func pushCTM() { ctmStack.append(ctm) }
        func popCTM() { ctm = ctmStack.popLast() ?? .identity }
        func concatenate(_ transform: CGAffineTransform) { ctm = transform.concatenating(ctm) }

        func moveTo(_ point: CGPoint) {
            closeSubpath()
            currentSubpath = [point.applying(ctm)]
        }

        func lineTo(_ point: CGPoint) {
            currentSubpath.append(point.applying(ctm))
        }

        func rectangle(_ rect: CGRect) {
            closeSubpath()
            subpaths.append([
                CGPoint(x: rect.minX, y: rect.minY).applying(ctm),
                CGPoint(x: rect.maxX, y: rect.minY).applying(ctm),
                CGPoint(x: rect.maxX, y: rect.maxY).applying(ctm),
                CGPoint(x: rect.minX, y: rect.maxY).applying(ctm),
            ])
        }

        func closeSubpath() {
            if currentSubpath.count >= 3 { subpaths.append(currentSubpath) }
            currentSubpath = []
        }

        func fill() {
            closeSubpath()
            filledPolygons.append(contentsOf: subpaths)
            subpaths = []
        }

        func discardPath() {
            currentSubpath = []
            subpaths = []
        }
    }

    // MARK: Star detection

    /// DoD RNAV waypoint stars: one filled path holding a spike ring (4
    /// evenly spaced radial spikes) plus an inner ring around the hole.
    /// Returns deduped star centers (mean of the 4 spike tips).
    static func starCenters(in polygons: [[CGPoint]]) -> [CGPoint] {
        var centers: [CGPoint] = []
        for polygon in polygons {
            guard polygon.count >= 10, polygon.count <= 44 else { continue }
            for ring in rings(of: polygon) {
                guard let center = starCenter(ofRing: ring) else { continue }
                if centers.contains(where: { hypot($0.x - center.x, $0.y - center.y) < 5 }) { continue }
                centers.append(center)
            }
        }
        return centers
    }

    /// Splits a subpath into rings: a new ring starts when the path
    /// returns to the ring's first vertex (star outline, then hole).
    static func rings(of polygon: [CGPoint]) -> [[CGPoint]] {
        var out: [[CGPoint]] = []
        var current: [CGPoint] = []
        for point in polygon {
            if let first = current.first, hypot(point.x - first.x, point.y - first.y) < 0.05 {
                out.append(current)
                current = []
            } else {
                current.append(point)
            }
        }
        if current.count >= 3 { out.append(current) }
        return out
    }

    static func starCenter(ofRing ring: [CGPoint]) -> CGPoint? {
        let count = ring.count
        guard count >= 8, count <= 20 else { return nil }
        let cx = ring.map(\.x).reduce(0, +) / CGFloat(count)
        let cy = ring.map(\.y).reduce(0, +) / CGFloat(count)
        let radii = ring.map { Double(hypot($0.x - cx, $0.y - cy)) }
        guard let maxRadius = radii.max(), maxRadius > 3, maxRadius < 16 else { return nil }

        // Circular local maxima above 1.6x the median radius, collapsed.
        let median = radii.sorted()[count / 2]
        guard median > 0.3 else { return nil }
        var spikes: [Int] = []
        for index in 0..<count {
            let radius = radii[index]
            guard radius > median * 1.6,
                  radius >= radii[(index + count - 1) % count],
                  radius >= radii[(index + 1) % count] else { continue }
            if let last = spikes.last, index - last <= 1 { continue }
            spikes.append(index)
        }
        if spikes.count >= 2, let first = spikes.first, let last = spikes.last,
           (first + count - last) <= 1 { spikes.removeLast() }
        guard spikes.count == 4 else { return nil }

        // Quarter-turn spacing.
        let gaps = (0..<4).map { (spikes[($0 + 1) % 4] - spikes[$0] + count) % count }
        let meanGap = Double(count) / 4
        guard gaps.allSatisfy({ Double($0) > meanGap * 0.4 && Double($0) < meanGap * 1.6 }) else { return nil }

        // Center from the tips; they must surround it.
        let tips = spikes.map { ring[$0] }
        let tipX = tips.map(\.x).reduce(0, +) / 4
        let tipY = tips.map(\.y).reduce(0, +) / 4
        let spread = tips.map { Double(hypot($0.x - tipX, $0.y - tipY)) }
        guard spread.min()! > maxRadius * 0.5 else { return nil }
        return CGPoint(x: tipX, y: tipY)
    }

    // MARK: Registration

    struct Similarity {
        /// q = [a −b; b a] p + t, page points → local meters.
        var a: Double
        var b: Double
        var t: SIMD2<Double>

        var scale: Double { (a * a + b * b).squareRoot() }
        var rotationDegrees: Double { atan2(b, a) * 180 / .pi }

        func apply(_ point: CGPoint) -> SIMD2<Double> {
            SIMD2(
                a * Double(point.x) - b * Double(point.y) + t.x,
                b * Double(point.x) + a * Double(point.y) + t.y
            )
        }
    }

    /// Equirectangular projection around the candidate centroid — accurate
    /// to well under a meter at planview scale.
    struct LocalProjection {
        let originLatitude: Double
        let originLongitude: Double
        private var metersPerDegreeLon: Double { 111_320 * cos(originLatitude * .pi / 180) }

        func meters(latitude: Double, longitude: Double) -> SIMD2<Double> {
            SIMD2(
                (longitude - originLongitude) * metersPerDegreeLon,
                (latitude - originLatitude) * 111_320
            )
        }

        func coordinate(fromMeters point: SIMD2<Double>) -> CLLocationCoordinate2D {
            CLLocationCoordinate2D(
                latitude: originLatitude + point.y / 111_320,
                longitude: originLongitude + point.x / metersPerDegreeLon
            )
        }
    }

    struct Fit {
        var transform: Similarity
        var projection: LocalProjection
        var rmsMeters: Double
        var inlierPagePoints: [CGPoint]
        var inlierIdentifiers: [String]
    }

    /// North-up-constrained RANSAC: every (star pair, candidate pair) whose
    /// direction and implied scale are chart-plausible seeds a similarity;
    /// stars are greedily matched to nearest candidates, refit, and the
    /// best hypothesis by (inlier count, normalized rms) wins — if it
    /// passes the gates.
    static func register(stars: [CGPoint], candidates: [Candidate]) -> Fit? {
        let projection = LocalProjection(
            originLatitude: candidates.map(\.latitude).reduce(0, +) / Double(candidates.count),
            originLongitude: candidates.map(\.longitude).reduce(0, +) / Double(candidates.count)
        )
        let meters = candidates.map { projection.meters(latitude: $0.latitude, longitude: $0.longitude) }

        // Spatial grid for nearest-candidate lookup (cells of 2 km; match
        // tolerances stay under 1.5 km at the max plausible scale).
        let cellSize = 2_000.0
        var grid: [SIMD2<Int32>: [Int]] = [:]
        for (index, m) in meters.enumerated() {
            grid[SIMD2(Int32((m.x / cellSize).rounded(.down)), Int32((m.y / cellSize).rounded(.down))), default: []].append(index)
        }
        func nearest(to q: SIMD2<Double>, within tolerance: Double, excluding used: Set<Int>) -> (index: Int, distance: Double)? {
            let reach = Int32((tolerance / cellSize).rounded(.up))
            let cx = Int32((q.x / cellSize).rounded(.down)), cy = Int32((q.y / cellSize).rounded(.down))
            var best: (Int, Double)?
            for dx in -reach...reach {
                for dy in -reach...reach {
                    for index in grid[SIMD2(cx + dx, cy + dy)] ?? [] where !used.contains(index) {
                        let d = meters[index] - q
                        let distance = (d.x * d.x + d.y * d.y).squareRoot()
                        if distance < tolerance, distance < (best?.1 ?? .infinity) {
                            best = (index, distance)
                        }
                    }
                }
            }
            return best.map { (index: $0.0, distance: $0.1) }
        }

        let maxRotation = maxRotationDegrees * .pi / 180
        var best: Fit?
        var bestKey: (count: Int, normalizedRMS: Double) = (0, .infinity)

        func evaluate(scale: Double, rotation: Double, anchorPage: CGPoint, anchorMeters: SIMD2<Double>) {
            var transform = Similarity(
                a: scale * cos(rotation),
                b: scale * sin(rotation),
                t: .zero
            )
            transform.t = anchorMeters - transform.apply(anchorPage) + transform.t
            var pairs: [(page: CGPoint, index: Int)] = []
            var rms = 0.0
            // Match → refit → match → refit; tolerance in page points,
            // converted through the current scale estimate.
            for round in 0..<2 {
                let tolerance = transform.scale * (round == 0 ? 2.5 : 1.8)
                var used = Set<Int>()
                pairs = []
                for star in stars {
                    guard let hit = nearest(to: transform.apply(star), within: tolerance, excluding: used) else { continue }
                    used.insert(hit.index)
                    pairs.append((star, hit.index))
                }
                guard pairs.count >= 3,
                      let fit = similarityFit(pagePoints: pairs.map(\.page), meterPoints: pairs.map { meters[$0.index] })
                else { return }
                transform = fit.transform
                rms = fit.rms
            }
            guard pairs.count >= minInliers,
                  abs(transform.rotationDegrees) <= maxRotationDegrees,
                  scaleRange.contains(transform.scale),
                  rms <= rmsGatePagePoints * transform.scale else { return }
            let key = (pairs.count, rms / transform.scale)
            if key.0 > bestKey.count || (key.0 == bestKey.count && key.1 < bestKey.normalizedRMS) {
                bestKey = key
                best = Fit(
                    transform: transform,
                    projection: projection,
                    rmsMeters: rms,
                    inlierPagePoints: pairs.map(\.page),
                    inlierIdentifiers: pairs.map { candidates[$0.index].identifier }
                )
            }
        }

        // Anchor star pairs: widest separations first (best scale and
        // rotation leverage); capped — a correct fit only needs one.
        var starPairs: [(CGPoint, CGPoint, Double, Double)] = []
        for i in 0..<stars.count {
            for j in (i + 1)..<stars.count {
                let dx = Double(stars[j].x - stars[i].x), dy = Double(stars[j].y - stars[i].y)
                let length = (dx * dx + dy * dy).squareRoot()
                guard length > 25 else { continue }
                starPairs.append((stars[i], stars[j], length, atan2(dy, dx)))
            }
        }
        starPairs.sort { $0.2 > $1.2 }
        starPairs = Array(starPairs.prefix(60))

        for (pageA, _, pageLength, pageAngle) in starPairs {
            for ai in 0..<meters.count {
                for bi in 0..<meters.count where bi != ai {
                    let d = meters[bi] - meters[ai]
                    let meterLength = (d.x * d.x + d.y * d.y).squareRoot()
                    let scale = meterLength / pageLength
                    guard scaleRange.contains(scale) else { continue }
                    let rotation = atan2(sin(atan2(d.y, d.x) - pageAngle), cos(atan2(d.y, d.x) - pageAngle))
                    guard abs(rotation) < maxRotation else { continue }
                    evaluate(scale: scale, rotation: rotation, anchorPage: pageA, anchorMeters: meters[ai])
                }
            }
        }
        return best
    }

    /// Closed-form least-squares similarity (no reflection, no shear).
    static func similarityFit(pagePoints: [CGPoint], meterPoints: [SIMD2<Double>]) -> (transform: Similarity, rms: Double)? {
        guard pagePoints.count == meterPoints.count, pagePoints.count >= 2 else { return nil }
        let n = Double(pagePoints.count)
        let pMean = SIMD2(
            pagePoints.map { Double($0.x) }.reduce(0, +) / n,
            pagePoints.map { Double($0.y) }.reduce(0, +) / n
        )
        let qMean = meterPoints.reduce(SIMD2<Double>.zero, +) / n
        var numeratorA = 0.0, numeratorB = 0.0, denominator = 0.0
        for (page, meters) in zip(pagePoints, meterPoints) {
            let p = SIMD2(Double(page.x), Double(page.y)) - pMean
            let q = meters - qMean
            numeratorA += p.x * q.x + p.y * q.y
            numeratorB += p.x * q.y - p.y * q.x
            denominator += p.x * p.x + p.y * p.y
        }
        guard denominator > 0 else { return nil }
        let a = numeratorA / denominator
        let b = numeratorB / denominator
        let t = qMean - SIMD2(a * pMean.x - b * pMean.y, b * pMean.x + a * pMean.y)
        let transform = Similarity(a: a, b: b, t: t)
        let squaredError = zip(pagePoints, meterPoints)
            .map { pair -> Double in
                let d = transform.apply(pair.0) - pair.1
                return d.x * d.x + d.y * d.y
            }
            .reduce(0, +)
        return (transform, (squaredError / n).squareRoot())
    }
}
