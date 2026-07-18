import Foundation
import CoreGraphics
import CoreLocation
import FBModels

/// Georeferences FAA airport diagrams (APDs), which — unlike IAPs — carry no
/// embedded geospatial metadata but ARE drawn to scale and conformal:
/// the diagram's drawn runways are matched to NASR's surveyed runway-end
/// coordinates and a 4-DOF similarity transform (scale/rotation/translation,
/// no shear) is fit by least squares. Any doubt → nil, and the UI degrades
/// exactly as it does today (no overlay).
///
/// Stages are `internal` so unit tests can exercise them individually.
enum AirportDiagramGeoreference {
    /// Bump to invalidate PlateGeoreferenceResolver's cached results after
    /// algorithm changes.
    static let matcherVersion = 1

    // MARK: Entry point

    static func match(url: URL, runways: [Runway]) -> PlateGeoreference? {
        let known = knownRunways(from: runways)
        guard !known.runways.isEmpty else { return nil }
        guard let document = CGPDFDocument(url as CFURL),
              let page = document.page(at: 1),
              page.rotationAngle == 0 else { return nil }
        let cropBox = page.getBoxRect(.cropBox)

        let polygons = filledPolygons(of: page)
        let candidates = candidateSegments(from: polygons)
        guard !candidates.isEmpty else { return nil }

        guard let fit = matchAndFit(candidates: candidates, known: known.runways) else { return nil }

        // Validation gates.
        if known.runways.count >= 2 {
            guard fit.matchedCount >= 2, fit.rmsMeters <= 20 else { return nil }
        } else {
            // A 2-point fit is exact; the residual proves nothing. Sanity-
            // check drawn width against NASR width and the page footprint.
            let runway = known.runways[0]
            if let widthFt = runway.widthFt {
                let drawnWidthMeters = Double(fit.matchedWidthPts) * fit.scaleMetersPerPoint
                let widthMeters = widthFt * 0.3048
                guard drawnWidthMeters > widthMeters * 0.5, drawnWidthMeters < widthMeters * 1.5 else { return nil }
            }
            let footprint = max(cropBox.width, cropBox.height) * fit.scaleMetersPerPoint
            guard footprint < 10_000 else { return nil }
        }

        // Page crop-box corners (PDF y-up) in raster order TL, TR, BR, BL.
        let pageCorners = [
            CGPoint(x: cropBox.minX, y: cropBox.maxY),
            CGPoint(x: cropBox.maxX, y: cropBox.maxY),
            CGPoint(x: cropBox.maxX, y: cropBox.minY),
            CGPoint(x: cropBox.minX, y: cropBox.minY),
        ]
        let corners = pageCorners.map { known.projection.coordinate(fromMeters: fit.transform.apply($0)) }
        guard corners.allSatisfy(CLLocationCoordinate2DIsValid) else { return nil }
        return PlateGeoreference(pageIndex: 1, pdfBBox: cropBox, corners: corners)
    }

    // MARK: Known runways (NASR side)

    struct KnownRunway {
        let designator: String
        /// Runway ends in local meters.
        let a: SIMD2<Double>
        let b: SIMD2<Double>
        let widthFt: Double?
        var length: Double { (b - a).length }
        /// Axis angle mod π.
        var axisAngle: Double { atan2(b.y - a.y, b.x - a.x).truncatedToHalfTurn }
    }

    /// Equirectangular projection around the airport — accurate to well
    /// under a meter at airport scale.
    struct LocalProjection {
        let originLatitude: Double
        let originLongitude: Double
        private var metersPerDegreeLon: Double { 111_320 * cos(originLatitude * .pi / 180) }

        func meters(from coordinate: Coordinate) -> SIMD2<Double> {
            SIMD2(
                (coordinate.longitude - originLongitude) * metersPerDegreeLon,
                (coordinate.latitude - originLatitude) * 111_320
            )
        }

        func coordinate(fromMeters point: SIMD2<Double>) -> CLLocationCoordinate2D {
            CLLocationCoordinate2D(
                latitude: originLatitude + point.y / 111_320,
                longitude: originLongitude + point.x / metersPerDegreeLon
            )
        }
    }

    static func knownRunways(from runways: [Runway]) -> (runways: [KnownRunway], projection: LocalProjection) {
        let coordinates = runways.flatMap(\.ends).compactMap(\.coordinate)
        guard !coordinates.isEmpty else { return ([], LocalProjection(originLatitude: 0, originLongitude: 0)) }
        let projection = LocalProjection(
            originLatitude: coordinates.map(\.latitude).reduce(0, +) / Double(coordinates.count),
            originLongitude: coordinates.map(\.longitude).reduce(0, +) / Double(coordinates.count)
        )
        let known = runways.compactMap { runway -> KnownRunway? in
            guard runway.ends.count == 2,
                  let coordA = runway.ends[0].coordinate,
                  let coordB = runway.ends[1].coordinate else { return nil }
            let a = projection.meters(from: coordA)
            let b = projection.meters(from: coordB)
            // Helipads and degenerate data would poison matching.
            guard (b - a).length > 150 else { return nil }
            return KnownRunway(designator: runway.designator, a: a, b: b, widthFt: runway.widthFeet.map(Double.init))
        }
        return (known, projection)
    }

    // MARK: PDF vector extraction

    /// Filled subpath polygons in page space (y-up), harvested by scanning
    /// the content stream's path + fill operators with the CTM applied.
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
            // Straight-enough sampling; runways are straight lines anyway.
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

    /// Mutable scan state handed to the C callbacks via the info pointer.
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
            filledPolygons.append(contentsOf: subpaths.filter { (3...12).contains($0.count) })
            subpaths = []
        }

        func discardPath() {
            currentSubpath = []
            subpaths = []
        }
    }

    // MARK: Candidate runway detection

    /// A candidate runway centerline in page space.
    struct Segment {
        var a: CGPoint
        var b: CGPoint
        var width: CGFloat
        var length: CGFloat { hypot(b.x - a.x, b.y - a.y) }
        /// Axis angle mod π.
        var axisAngle: Double { Double(atan2(b.y - a.y, b.x - a.x)).truncatedToHalfTurn }
    }

    static func candidateSegments(from polygons: [[CGPoint]]) -> [Segment] {
        var segments = polygons.compactMap(orientedSegment)
            .filter { $0.width > 0 && $0.length / $0.width >= 8 && $0.length >= 30 }
        guard let longest = segments.map(\.length).max() else { return [] }
        segments.removeAll { $0.length < longest * 0.15 }
        return mergeCollinear(segments)
    }

    /// PCA-based oriented bounding box → centerline segment + width.
    static func orientedSegment(of polygon: [CGPoint]) -> Segment? {
        guard polygon.count >= 3 else { return nil }
        let n = Double(polygon.count)
        let cx = polygon.map { Double($0.x) }.reduce(0, +) / n
        let cy = polygon.map { Double($0.y) }.reduce(0, +) / n
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for point in polygon {
            let dx = Double(point.x) - cx
            let dy = Double(point.y) - cy
            sxx += dx * dx
            syy += dy * dy
            sxy += dx * dy
        }
        let angle = 0.5 * atan2(2 * sxy, sxx - syy)
        let axis = SIMD2(cos(angle), sin(angle))
        let perpendicular = SIMD2(-axis.y, axis.x)
        var minAlong = Double.infinity, maxAlong = -Double.infinity
        var minAcross = Double.infinity, maxAcross = -Double.infinity
        for point in polygon {
            let d = SIMD2(Double(point.x) - cx, Double(point.y) - cy)
            let along = (d * axis).sum()
            let across = (d * perpendicular).sum()
            minAlong = min(minAlong, along); maxAlong = max(maxAlong, along)
            minAcross = min(minAcross, across); maxAcross = max(maxAcross, across)
        }
        let center = SIMD2(cx, cy)
        let start = center + axis * minAlong
        let end = center + axis * maxAlong
        return Segment(
            a: CGPoint(x: start.x, y: start.y),
            b: CGPoint(x: end.x, y: end.y),
            width: CGFloat(maxAcross - minAcross)
        )
    }

    /// Runways get split into multiple fills at intersections; merge
    /// candidates sharing an axis into one span.
    static func mergeCollinear(_ input: [Segment]) -> [Segment] {
        var segments = input
        var merged = true
        while merged {
            merged = false
            outer: for i in 0..<segments.count {
                for j in (i + 1)..<segments.count {
                    let s1 = segments[i], s2 = segments[j]
                    let angleDiff = halfTurnDifference(s1.axisAngle, s2.axisAngle)
                    guard angleDiff < 2 * .pi / 180 else { continue }
                    // Lateral offset of s2's midpoint from s1's axis.
                    let axis = SIMD2(cos(s1.axisAngle), sin(s1.axisAngle))
                    let perpendicular = SIMD2(-axis.y, axis.x)
                    let mid2 = SIMD2(Double(s2.a.x + s2.b.x) / 2, Double(s2.a.y + s2.b.y) / 2)
                    let origin = SIMD2(Double(s1.a.x), Double(s1.a.y))
                    let lateral = abs(((mid2 - origin) * perpendicular).sum())
                    guard lateral < Double(max(s1.width, s2.width)) else { continue }
                    // Merge: union of endpoint projections along the axis.
                    let points = [s1.a, s1.b, s2.a, s2.b].map { SIMD2(Double($0.x), Double($0.y)) }
                    let projections = points.map { (($0 - origin) * axis).sum() }
                    let lo = projections.min()!, hi = projections.max()!
                    let start = origin + axis * lo
                    let end = origin + axis * hi
                    segments[i] = Segment(
                        a: CGPoint(x: start.x, y: start.y),
                        b: CGPoint(x: end.x, y: end.y),
                        width: max(s1.width, s2.width)
                    )
                    segments.remove(at: j)
                    merged = true
                    break outer
                }
            }
        }
        return segments
    }

    // MARK: Matching + similarity fit

    struct Similarity {
        /// q = [a −b; b a] p + t, page points → local meters.
        var a: Double
        var b: Double
        var t: SIMD2<Double>

        var scale: Double { (a * a + b * b).squareRoot() }

        func apply(_ point: CGPoint) -> SIMD2<Double> {
            SIMD2(
                a * Double(point.x) - b * Double(point.y) + t.x,
                b * Double(point.x) + a * Double(point.y) + t.y
            )
        }
    }

    struct Fit {
        var transform: Similarity
        var rmsMeters: Double
        var matchedCount: Int
        var scaleMetersPerPoint: Double
        /// Drawn width (pts) of the matched candidate — single-runway sanity.
        var matchedWidthPts: CGFloat
    }

    static func matchAndFit(candidates: [Segment], known: [KnownRunway]) -> Fit? {
        guard let anchor = candidates.max(by: { $0.length < $1.length }) else { return nil }
        var best: Fit?

        for anchorRunway in known {
            let scale = anchorRunway.length / Double(anchor.length)  // meters per point
            // Greedily assign remaining candidates to remaining runways by
            // length + relative axis angle.
            var pairs: [(Segment, KnownRunway)] = [(anchor, anchorRunway)]
            var remainingRunways = known.filter { $0.designator != anchorRunway.designator }
            for candidate in candidates where candidate.a != anchor.a || candidate.b != anchor.b {
                let candidateRelativeAngle = halfTurnDifference(candidate.axisAngle, anchor.axisAngle)
                guard let index = remainingRunways.firstIndex(where: { runway in
                    abs(Double(candidate.length) * scale - runway.length) <= runway.length * 0.10
                        && abs(halfTurnDifference(runway.axisAngle, anchorRunway.axisAngle) - candidateRelativeAngle) < 3 * .pi / 180
                }) else { continue }
                pairs.append((candidate, remainingRunways[index]))
                remainingRunways.remove(at: index)
            }

            // True parallels of equal length are interchangeable by length
            // and angle alone; try every within-group runway permutation and
            // let the residual pick the right one.
            for assignment in runwayPermutations(of: pairs) {
            // Both polarities of the anchor seed the global rotation; each
            // remaining pair takes whichever polarity agrees with it.
            for anchorFlipped in [false, true] {
                var pagePoints: [CGPoint] = []
                var meterPoints: [SIMD2<Double>] = []
                let anchorPair = assignment[0]
                let (pa, pb) = anchorFlipped ? (anchorPair.0.b, anchorPair.0.a) : (anchorPair.0.a, anchorPair.0.b)
                pagePoints += [pa, pb]
                meterPoints += [anchorPair.1.a, anchorPair.1.b]
                let theta = fullAngle(from: pa, to: pb, targetFrom: anchorPair.1.a, targetTo: anchorPair.1.b)

                for (candidate, runway) in assignment.dropFirst() {
                    let straight = fullAngle(from: candidate.a, to: candidate.b, targetFrom: runway.a, targetTo: runway.b)
                    if angularDifference(straight, theta) < .pi / 2 {
                        pagePoints += [candidate.a, candidate.b]
                        meterPoints += [runway.a, runway.b]
                    } else {
                        pagePoints += [candidate.b, candidate.a]
                        meterPoints += [runway.a, runway.b]
                    }
                }

                guard let fit = similarityFit(pagePoints: pagePoints, meterPoints: meterPoints) else { continue }
                let result = Fit(
                    transform: fit.transform,
                    rmsMeters: fit.rms,
                    matchedCount: assignment.count,
                    scaleMetersPerPoint: fit.transform.scale,
                    matchedWidthPts: anchorPair.0.width
                )
                if best == nil
                    || result.matchedCount > best!.matchedCount
                    || (result.matchedCount == best!.matchedCount && result.rmsMeters < best!.rmsMeters) {
                    best = result
                }
            }
            }
        }
        return best
    }

    /// All assignments obtained by permuting runways within groups that are
    /// interchangeable by length (10%) and axis angle (3°) — i.e. true
    /// parallels. Capped; airports don't have many parallels.
    static func runwayPermutations(of pairs: [(Segment, KnownRunway)], cap: Int = 24) -> [[(Segment, KnownRunway)]] {
        var groups: [[Int]] = []
        var grouped = Set<Int>()
        for i in pairs.indices where !grouped.contains(i) {
            var group = [i]
            grouped.insert(i)
            for j in pairs.indices where !grouped.contains(j) {
                let a = pairs[i].1, b = pairs[j].1
                if abs(a.length - b.length) <= min(a.length, b.length) * 0.10,
                   halfTurnDifference(a.axisAngle, b.axisAngle) < 3 * .pi / 180 {
                    group.append(j)
                    grouped.insert(j)
                }
            }
            groups.append(group)
        }

        var results = [pairs]
        for group in groups where group.count > 1 {
            var expanded: [[(Segment, KnownRunway)]] = []
            for base in results {
                for permutation in permutations(of: group.map { base[$0].1 }) {
                    var variant = base
                    for (offset, index) in group.enumerated() {
                        variant[index].1 = permutation[offset]
                    }
                    expanded.append(variant)
                    if expanded.count >= cap { break }
                }
                if expanded.count >= cap { break }
            }
            results = expanded
        }
        return results
    }

    private static func permutations(of runways: [KnownRunway]) -> [[KnownRunway]] {
        guard runways.count > 1 else { return [runways] }
        return runways.indices.flatMap { index -> [[KnownRunway]] in
            var rest = runways
            let head = rest.remove(at: index)
            return permutations(of: rest).map { [head] + $0 }
        }
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
            .map { (transform.apply($0) - $1).lengthSquared }
            .reduce(0, +)
        return (transform, (squaredError / n).squareRoot())
    }

    // MARK: Angle helpers

    private static func fullAngle(from a: CGPoint, to b: CGPoint, targetFrom: SIMD2<Double>, targetTo: SIMD2<Double>) -> Double {
        let pageAngle = atan2(Double(b.y - a.y), Double(b.x - a.x))
        let meterAngle = atan2(targetTo.y - targetFrom.y, targetTo.x - targetFrom.x)
        return meterAngle - pageAngle
    }

    static func halfTurnDifference(_ a: Double, _ b: Double) -> Double {
        var difference = abs(a - b).truncatingRemainder(dividingBy: .pi)
        if difference > .pi / 2 { difference = .pi - difference }
        return difference
    }

    private static func angularDifference(_ a: Double, _ b: Double) -> Double {
        var difference = abs(a - b).truncatingRemainder(dividingBy: 2 * .pi)
        if difference > .pi { difference = 2 * .pi - difference }
        return difference
    }
}

private extension SIMD2<Double> {
    var length: Double { (x * x + y * y).squareRoot() }
    var lengthSquared: Double { x * x + y * y }
}

private extension Double {
    /// Angle normalized to [0, π).
    var truncatedToHalfTurn: Double {
        var value = truncatingRemainder(dividingBy: .pi)
        if value < 0 { value += .pi }
        return value
    }
}
