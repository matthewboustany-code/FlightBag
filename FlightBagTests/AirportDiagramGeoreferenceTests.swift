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

private extension SIMD2<Double> {
    var lengthMeters: Double { (x * x + y * y).squareRoot() }
}
