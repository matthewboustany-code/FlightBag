import Foundation
import CoreGraphics
import CoreLocation
import Testing
@testable import FlightBag

@Suite struct PlateGeoreferenceTests {
    /// Minimal hand-assembled PDF with (optionally) an FAA-style geospatial
    /// viewport. Offsets are computed while concatenating so the xref is
    /// valid; no FAA content involved.
    private func synthesizedPDF(
        includeViewport: Bool,
        gpts: String = "29 -98 29 -97 30 -97 30 -98",
        lpts: String = "0 0 1 0 1 1 0 1"
    ) -> Data {
        let viewport = includeViewport ? """
        /VP [<< /Type /Viewport /BBox [10 20 390 580] /Measure << /Type /Measure /Subtype /GEO \
        /Bounds [0 0 0 1 1 1 1 0] \
        /GPTS [\(gpts)] \
        /LPTS [\(lpts)] >> >>]
        """ : ""
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 600] \(viewport) >>",
        ]
        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(body)\nendobj\n"
        }
        let xrefOffset = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets {
            pdf += String(format: "%010d 00000 n \n", offset)
        }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        return Data(pdf.utf8)
    }

    private func write(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("georef-\(UUID().uuidString).pdf")
        try data.write(to: url)
        return url
    }

    @Test func parsesViewportAndNormalizesCorners() throws {
        let url = try write(synthesizedPDF(includeViewport: true))
        defer { try? FileManager.default.removeItem(at: url) }

        let georef = try #require(PlateGeoreference.parse(url: url))
        #expect(georef.pageIndex == 1)
        #expect(georef.pdfBBox == CGRect(x: 10, y: 20, width: 380, height: 560))
        // GPTS order in the fixture is BL, BR, TR, TL (via LPTS); parsed
        // corners must come out normalized TL, TR, BR, BL.
        let expected = [(30.0, -98.0), (30.0, -97.0), (29.0, -97.0), (29.0, -98.0)]
        #expect(georef.corners.count == 4)
        for (corner, (lat, lon)) in zip(georef.corners, expected) {
            #expect(abs(corner.latitude - lat) < 1e-9)
            #expect(abs(corner.longitude - lon) < 1e-9)
        }
    }

    @Test func extrapolatesInsetRegistrationRing() throws {
        // Real FAA charts register on an inset 0.1…0.9 ring, not the
        // corners (values from the KAUS ILS 18L chart).
        let url = try write(synthesizedPDF(
            includeViewport: true,
            gpts: "29.89082498591 -97.93014344643 29.89082494368 -97.3907790727 30.64046326543 -97.38886317304 30.64046330794 -97.93205919033",
            lpts: "0.1 0.1 0.9 0.1 0.9 0.9 0.1 0.9"
        ))
        defer { try? FileManager.default.removeItem(at: url) }

        let georef = try #require(PlateGeoreference.parse(url: url))
        // Corners extrapolate ~0.09° beyond the ring (verified numerically).
        let expected = [(30.73417, -97.99876), (30.73417, -97.32216), (29.79712, -97.32216), (29.79712, -97.99876)]
        for (corner, (lat, lon)) in zip(georef.corners, expected) {
            #expect(abs(corner.latitude - lat) < 0.0001)
            #expect(abs(corner.longitude - lon) < 0.0001)
        }
    }

    @Test func plainPDFReturnsNil() throws {
        let url = try write(synthesizedPDF(includeViewport: false))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(PlateGeoreference.parse(url: url) == nil)
    }
}
