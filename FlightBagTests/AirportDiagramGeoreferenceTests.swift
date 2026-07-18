import Foundation
import CoreGraphics
import CoreLocation
import UIKit
import Testing
import FBModels
@testable import FlightBag

@Suite struct AirportDiagramGeoreferenceTests {
    // MARK: Synthetic airport + drawing

    /// A synthetic airport: runways defined in local meters around an
    /// origin, drawn into a real PDF through a known meters→page similarity
    /// (scale, rotation, translation). The matcher must recover it.
    private struct Fixture {
        static let originLat = 30.0
        static let originLon = -97.0

        let runways: [Runway]
        /// Runway centerlines in local meters (a, b, halfWidthMeters).
        let centerlines: [(SIMD2<Double>, SIMD2<Double>, Double)]

        /// meters → page points.
        let scale: Double
        let rotation: Double
        let translation: SIMD2<Double>

        func pagePoint(_ meters: SIMD2<Double>) -> CGPoint {
            let x = (meters.x * cos(rotation) - meters.y * sin(rotation)) * scale + translation.x
            let y = (meters.x * sin(rotation) + meters.y * cos(rotation)) * scale + translation.y
            return CGPoint(x: x, y: y)
        }

        func coordinate(_ meters: SIMD2<Double>) -> Coordinate {
            Coordinate(
                latitude: Self.originLat + meters.y / 111_320,
                longitude: Self.originLon + meters.x / (111_320 * cos(Self.originLat * .pi / 180))
            )
        }

        static func runway(designator: String, headings: (Double, Double), center: SIMD2<Double>, lengthMeters: Double, widthFeet: Int, in fixture: inout [(String, SIMD2<Double>, SIMD2<Double>, Int, (Double, Double))]) {
            // True heading h: meters direction (sin h, cos h).
            let direction = SIMD2(sin(headings.0 * .pi / 180), cos(headings.0 * .pi / 180))
            let a = center - direction * (lengthMeters / 2)
            let b = center + direction * (lengthMeters / 2)
            fixture.append((designator, a, b, widthFeet, headings))
        }

        init(runwayDefs: [(String, SIMD2<Double>, SIMD2<Double>, Int, (Double, Double))], scale: Double, rotationDegrees: Double, translation: SIMD2<Double>) {
            self.scale = scale
            self.rotation = rotationDegrees * .pi / 180
            self.translation = translation
            var runways: [Runway] = []
            var centerlines: [(SIMD2<Double>, SIMD2<Double>, Double)] = []
            for (designator, a, b, widthFeet, headings) in runwayDefs {
                let parts = designator.split(separator: "/").map(String.init)
                func coord(_ meters: SIMD2<Double>) -> Coordinate {
                    Coordinate(
                        latitude: Self.originLat + meters.y / 111_320,
                        longitude: Self.originLon + meters.x / (111_320 * cos(Self.originLat * .pi / 180))
                    )
                }
                runways.append(Runway(
                    designator: designator,
                    lengthFeet: Int((b - a).lengthMeters / 0.3048),
                    widthFeet: widthFeet,
                    ends: [
                        RunwayEnd(designator: parts[0], trueHeading: headings.0, coordinate: coord(a)),
                        RunwayEnd(designator: parts.count > 1 ? parts[1] : parts[0], trueHeading: headings.1, coordinate: coord(b)),
                    ]
                ))
                centerlines.append((a, b, Double(widthFeet) * 0.3048 / 2))
            }
            self.runways = runways
            self.centerlines = centerlines
        }

        /// Draw the runways as filled quads into a real PDF (exercises the
        /// content-stream scanner honestly, including the UIKit flip CTM).
        /// UIGraphicsPDFRenderer draws in y-down UIKit space; `pagePoint`
        /// values are PDF page space (y-up), so flip when drawing.
        func makePDF(extraShapesOnly: Bool = false) throws -> URL {
            let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
            func drawPoint(_ page: CGPoint) -> CGPoint {
                CGPoint(x: page.x, y: pageRect.height - page.y)
            }
            let data = UIGraphicsPDFRenderer(bounds: pageRect).pdfData { context in
                context.beginPage()
                let cg = context.cgContext
                UIColor.black.setFill()
                if !extraShapesOnly {
                    for (a, b, halfWidthMeters) in centerlines {
                        let pa = drawPoint(pagePoint(a))
                        let pb = drawPoint(pagePoint(b))
                        let axis = SIMD2(Double(pb.x - pa.x), Double(pb.y - pa.y))
                        let length = (axis.x * axis.x + axis.y * axis.y).squareRoot()
                        let perp = SIMD2(-axis.y / length, axis.x / length) * (halfWidthMeters * scale)
                        let path = CGMutablePath()
                        path.move(to: CGPoint(x: Double(pa.x) + perp.x, y: Double(pa.y) + perp.y))
                        path.addLine(to: CGPoint(x: Double(pb.x) + perp.x, y: Double(pb.y) + perp.y))
                        path.addLine(to: CGPoint(x: Double(pb.x) - perp.x, y: Double(pb.y) - perp.y))
                        path.addLine(to: CGPoint(x: Double(pa.x) - perp.x, y: Double(pa.y) - perp.y))
                        path.closeSubpath()
                        cg.addPath(path)
                        cg.fillPath()
                    }
                }
                // Distractors every diagram has: a border rule, small boxes.
                cg.fill(CGRect(x: 40, y: 40, width: 60, height: 20))
                cg.fill(CGRect(x: 500, y: 700, width: 12, height: 12))
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("apd-\(UUID().uuidString).pdf")
            try data.write(to: url)
            return url
        }
    }

    private func makeCrossingFixture() -> Fixture {
        var defs: [(String, SIMD2<Double>, SIMD2<Double>, Int, (Double, Double))] = []
        Fixture.runway(designator: "17/35", headings: (170, 350), center: .zero, lengthMeters: 2700, widthFeet: 150, in: &defs)
        Fixture.runway(designator: "13/31", headings: (130, 310), center: SIMD2(400, 300), lengthMeters: 1800, widthFeet: 100, in: &defs)
        return Fixture(runwayDefs: defs, scale: 0.10, rotationDegrees: 12, translation: SIMD2(300, 400))
    }

    // MARK: Tests

    @Test func recoversKnownTransformForCrossingRunways() throws {
        let fixture = makeCrossingFixture()
        let url = try fixture.makePDF()
        defer { try? FileManager.default.removeItem(at: url) }

        let georef = try #require(AirportDiagramGeoreference.match(url: url, runways: fixture.runways))
        #expect(georef.pageIndex == 1)

        // Independently compute the expected geographic corner for the
        // page's TL corner via the known inverse transform.
        func expectedCoordinate(ofPagePoint page: CGPoint) -> Coordinate {
            let translated = SIMD2(Double(page.x) - fixture.translation.x, Double(page.y) - fixture.translation.y)
            let unrotated = SIMD2(
                translated.x * cos(-fixture.rotation) - translated.y * sin(-fixture.rotation),
                translated.x * sin(-fixture.rotation) + translated.y * cos(-fixture.rotation)
            )
            return fixture.coordinate(unrotated / fixture.scale)
        }

        let bbox = georef.pdfBBox
        let pageCorners = [
            CGPoint(x: bbox.minX, y: bbox.maxY),
            CGPoint(x: bbox.maxX, y: bbox.maxY),
            CGPoint(x: bbox.maxX, y: bbox.minY),
            CGPoint(x: bbox.minX, y: bbox.minY),
        ]
        for (corner, page) in zip(georef.corners, pageCorners) {
            let expected = expectedCoordinate(ofPagePoint: page)
            // 2×10⁻⁴ degrees ≈ 20 m.
            #expect(abs(corner.latitude - expected.latitude) < 2e-4)
            #expect(abs(corner.longitude - expected.longitude) < 2e-4)
        }
    }

    @Test func disambiguatesEqualParallelRunways() throws {
        var defs: [(String, SIMD2<Double>, SIMD2<Double>, Int, (Double, Double))] = []
        Fixture.runway(designator: "18L/36R", headings: (180, 360), center: SIMD2(-500, 0), lengthMeters: 2400, widthFeet: 150, in: &defs)
        Fixture.runway(designator: "18R/36L", headings: (180, 360), center: SIMD2(500, 0), lengthMeters: 2400, widthFeet: 150, in: &defs)
        Fixture.runway(designator: "09/27", headings: (90, 270), center: SIMD2(0, -800), lengthMeters: 1700, widthFeet: 100, in: &defs)
        let fixture = Fixture(runwayDefs: defs, scale: 0.09, rotationDegrees: -8, translation: SIMD2(310, 390))
        let url = try fixture.makePDF()
        defer { try? FileManager.default.removeItem(at: url) }

        let georef = try #require(AirportDiagramGeoreference.match(url: url, runways: fixture.runways))
        // Wrong parallel assignment would shift the fit ~1 km laterally;
        // the centroid landing near the airport proves the permutation
        // search picked correctly.
        let centroidLat = georef.corners.map(\.latitude).reduce(0, +) / 4
        let centroidLon = georef.corners.map(\.longitude).reduce(0, +) / 4
        #expect(abs(centroidLat - Fixture.originLat) < 0.01)
        #expect(abs(centroidLon - Fixture.originLon) < 0.01)
    }

    @Test func noRunwayShapesReturnsNil() throws {
        let fixture = makeCrossingFixture()
        let url = try fixture.makePDF(extraShapesOnly: true)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(AirportDiagramGeoreference.match(url: url, runways: fixture.runways) == nil)
    }

    @Test func contradictoryRunwayDataReturnsNil() throws {
        let fixture = makeCrossingFixture()
        let url = try fixture.makePDF()
        defer { try? FileManager.default.removeItem(at: url) }
        // Same drawing, but claim wildly different ground truth: lengths
        // that can't both match any one scale.
        var defs: [(String, SIMD2<Double>, SIMD2<Double>, Int, (Double, Double))] = []
        Fixture.runway(designator: "17/35", headings: (170, 350), center: .zero, lengthMeters: 2700, widthFeet: 150, in: &defs)
        Fixture.runway(designator: "13/31", headings: (130, 310), center: SIMD2(400, 300), lengthMeters: 600, widthFeet: 100, in: &defs)
        let wrong = Fixture(runwayDefs: defs, scale: 0.10, rotationDegrees: 12, translation: SIMD2(300, 400))
        let result = AirportDiagramGeoreference.match(url: url, runways: wrong.runways)
        // Only one runway can match a given scale → multi-runway gate
        // (≥2 matches) rejects.
        #expect(result == nil)
    }

    // MARK: Stage tests

    @Test func orientedSegmentMeasuresAThinQuad() {
        let segment = AirportDiagramGeoreference.orientedSegment(of: [
            CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 0),
            CGPoint(x: 200, y: 10), CGPoint(x: 0, y: 10),
        ])!
        #expect(abs(segment.length - 200) < 1)
        #expect(abs(segment.width - 10) < 1)
    }

    @Test func mergesCollinearSplitRunway() {
        let merged = AirportDiagramGeoreference.mergeCollinear([
            .init(a: CGPoint(x: 0, y: 0), b: CGPoint(x: 100, y: 0), width: 8),
            .init(a: CGPoint(x: 110, y: 0.5), b: CGPoint(x: 260, y: 1), width: 8),
        ])
        #expect(merged.count == 1)
        #expect(abs(merged[0].length - 260) < 3)
    }

    @Test func similarityFitRecoversScaleAndRotation() {
        // 90° rotation, scale 2: (1,0)→(0,2).
        let fit = AirportDiagramGeoreference.similarityFit(
            pagePoints: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1)],
            meterPoints: [SIMD2(0, 0), SIMD2(0, 2), SIMD2(-2, 0)]
        )!
        #expect(abs(fit.transform.scale - 2) < 1e-9)
        #expect(fit.rms < 1e-9)
    }
}

/// Real current-cycle FAA airport diagrams (d-TPP 2607). The synthetic
/// fixtures above draw runways as clean 4-vertex quads; real diagrams draw
/// them as single filled polygons with 14–45 vertices (displaced
/// thresholds, notches), which a former vertex cap silently dropped —
/// every real APD failed to georeference while all synthetic tests passed.
/// Runway truth comes from NASR (Server artifacts aero.sqlite, cycle 2607).
@Suite struct AirportDiagramRealFixtureTests {
    struct RealDiagram: Sendable {
        let fixture: String
        let runways: [Runway]
    }

    private static func runway(_ designator: String, width: Int, _ endA: (String, Double, Double), _ endB: (String, Double, Double)) -> Runway {
        Runway(designator: designator, widthFeet: width, ends: [
            RunwayEnd(designator: endA.0, coordinate: Coordinate(latitude: endA.1, longitude: endA.2)),
            RunwayEnd(designator: endB.0, coordinate: Coordinate(latitude: endB.1, longitude: endB.2)),
        ])
    }

    static let diagrams: [RealDiagram] = [
        // KAUS 00556AD: two long parallels + helipads (filtered out).
        RealDiagram(fixture: "KAUS-APD-2607", runways: [
            runway("18L/36R", width: 150, ("18L", 30.20383005, -97.65789105), ("36R", 30.17909102, -97.65724333)),
            runway("18R/36L", width: 150, ("18R", 30.21361613, -97.67936477), ("36L", 30.17994322, -97.67847469)),
            Runway(designator: "H1", widthFeet: 60, ends: [
                RunwayEnd(designator: "H1", coordinate: Coordinate(latitude: 30.185475, longitude: -97.66100555)),
            ]),
        ]),
        // KSEA 00582AD: three parallels of similar-but-distinct length —
        // regression coverage for greedy misassignment (2594m drawn runway
        // also within 10% of the 2876m runway).
        RealDiagram(fixture: "KSEA-APD-2607", runways: [
            runway("16C/34C", width: 150, ("16C", 47.46380986, -122.31098375), ("34C", 47.43797127, -122.31120983)),
            runway("16L/34R", width: 150, ("16L", 47.46379522, -122.30775022), ("34R", 47.43117227, -122.30803825)),
            runway("16R/34L", width: 150, ("16R", 47.46383636, -122.31785683), ("34L", 47.4405338, -122.31805805)),
        ]),
        // KNIP 00209AD: DoD-drawn diagram; Rwy 10/28 is one 24-vertex fill.
        RealDiagram(fixture: "KNIP-APD-2607", runways: [
            runway("10/28", width: 200, ("10", 30.23158888, -81.69293611), ("28", 30.23173333, -81.66443055)),
            runway("14/32", width: 200, ("14", 30.24256666, -81.67883416), ("32", 30.23100833, -81.66537222)),
        ]),
        // KNUW 00451AD: crossing runways drawn as 14- and 21-vertex fills.
        RealDiagram(fixture: "KNUW-APD-2607", runways: [
            runway("07/25", width: 200, ("07", 48.35130541, -122.67288038), ("25", 48.35246413, -122.64003061)),
            runway("14/32", width: 200, ("14", 48.36170344, -122.66250877), ("32", 48.34188527, -122.64841891)),
        ]),
    ]

    @Test(arguments: diagrams) func georeferencesRealDiagram(_ diagram: RealDiagram) throws {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: diagram.fixture, withExtension: "pdf"))

        // Stage-level: the fit itself must be multi-runway and tight.
        let known = AirportDiagramGeoreference.knownRunways(from: diagram.runways)
        let document = try #require(CGPDFDocument(url as CFURL))
        let page = try #require(document.page(at: 1))
        let polygons = AirportDiagramGeoreference.filledPolygons(of: page)
        let candidates = AirportDiagramGeoreference.candidateSegments(from: polygons)
        let fit = try #require(AirportDiagramGeoreference.matchAndFit(candidates: candidates, known: known.runways))
        #expect(fit.matchedCount >= 2)
        #expect(fit.rmsMeters <= 20)

        // End-to-end: match() accepts, and the geographic corner quad
        // contains every surveyed runway end.
        let georef = try #require(AirportDiagramGeoreference.match(url: url, runways: diagram.runways))
        let latitudes = georef.corners.map(\.latitude)
        let longitudes = georef.corners.map(\.longitude)
        for end in diagram.runways.flatMap(\.ends) {
            guard let coordinate = end.coordinate else { continue }
            #expect(coordinate.latitude > latitudes.min()! && coordinate.latitude < latitudes.max()!)
            #expect(coordinate.longitude > longitudes.min()! && coordinate.longitude < longitudes.max()!)
        }
    }
}

/// Anchor for locating the test bundle from struct-based suites.
private final class BundleToken {}

private extension SIMD2<Double> {
    var lengthMeters: Double { (x * x + y * y).squareRoot() }
}
