import Foundation
import Testing
@testable import FBFISB

@Suite struct DLACTests {
    @Test func decodesKnownVector() {
        // Codes A(1) B(2) C(3) D(4) pack to 04 20 C4.
        #expect(DLAC.decode([0x04, 0x20, 0xC4]) == "ABCD")
    }

    @Test func roundTripsMETARText() {
        let text = "METAR KAUS 151953Z 18010KT 10SM SCT045 33/17 A3002"
        #expect(DLAC.decode(DLAC.encode(text)) == text)
    }

    @Test func decodesTabRunAsSpaces() {
        // Codes A(1), tab-marker(28), count 3, B(2) → "A   B".
        #expect(DLAC.decode([0x05, 0xC0, 0xC2]) == "A   B")
    }

    @Test func truncatedInputDoesNotCrash() {
        let bytes = DLAC.encode("METAR KAUS 151953Z")
        for length in 0..<bytes.count {
            _ = DLAC.decode(Array(bytes.prefix(length)))
        }
    }
}

@Suite struct UATUplinkFrameTests {
    private func textAPDU(_ text: String) -> [UInt8] {
        FISBEncoding.apdu(productID: 413, hours: 19, minutes: 53, payload: DLAC.encode(text))
    }

    @Test func parsesMultipleInfoFrames() {
        let frame = FISBEncoding.uplinkFrame(infoFrames: [
            FISBEncoding.infoFrame(body: textAPDU("METAR KAUS 151953Z")),
            FISBEncoding.infoFrame(body: textAPDU("TAF KDAL 151800Z")),
        ])
        let parsed = UATUplinkFrame.parse(frame)
        #expect(parsed?.applicationDataValid == true)
        #expect(parsed?.apdus.count == 2)
        #expect(parsed?.apdus.first?.productID == 413)
        #expect(parsed?.apdus.first?.hours == 19)
        #expect(parsed?.apdus.first?.minutes == 53)
    }

    @Test func zeroLengthFrameTerminatesIteration() {
        // Padding after one frame is all zeros: exactly one APDU.
        let frame = FISBEncoding.uplinkFrame(infoFrames: [
            FISBEncoding.infoFrame(body: textAPDU("METAR KAUS 151953Z"))
        ])
        #expect(UATUplinkFrame.parse(frame)?.apdus.count == 1)
    }

    @Test func skipsNonAPDUFrameTypes() {
        let frame = FISBEncoding.uplinkFrame(infoFrames: [
            FISBEncoding.infoFrame(type: 14, body: [0xDE, 0xAD]),
            FISBEncoding.infoFrame(body: textAPDU("METAR KAUS 151953Z")),
        ])
        let parsed = UATUplinkFrame.parse(frame)
        #expect(parsed?.apdus.count == 1)
        #expect(parsed?.skippedFrameTypes == [14])
    }

    @Test func appDataInvalidYieldsNoAPDUs() {
        var frame = FISBEncoding.uplinkFrame(infoFrames: [
            FISBEncoding.infoFrame(body: textAPDU("METAR KAUS 151953Z"))
        ])
        frame[6] = 0  // clear application-data-valid
        let parsed = UATUplinkFrame.parse(frame)
        #expect(parsed?.applicationDataValid == false)
        #expect(parsed?.apdus.isEmpty == true)
    }

    @Test func truncatedFramesNeverCrash() {
        let frame = FISBEncoding.uplinkFrame(infoFrames: [
            FISBEncoding.infoFrame(body: textAPDU("METAR KAUS 151953Z"))
        ])
        for length in 0..<frame.count {
            _ = UATUplinkFrame.parse(Array(frame.prefix(length)))
        }
    }
}

@Suite struct FISBAPDUTests {
    @Test func decodesTimeOption2Header() {
        // Product 413, month 7 day 15, 19:53Z, unsegmented, payload AB CD.
        let body: [UInt8] = [0x06, 0x75, 0x3B, 0xE7, 0xA8, 0xAB, 0xCD]
        let apdu = FISBAPDU.parse(body)
        #expect(apdu?.productID == 413)
        #expect(apdu?.isSegmented == false)
        #expect(apdu?.month == 7)
        #expect(apdu?.day == 15)
        #expect(apdu?.hours == 19)
        #expect(apdu?.minutes == 53)
        #expect(apdu?.payload == [0xAB, 0xCD])
    }

    @Test func detectsSegmentedAPDU() {
        var body = FISBEncoding.apdu(productID: 63, hours: 1, minutes: 2, payload: [0x00])
        body[1] |= 0x02
        let apdu = FISBAPDU.parse(body)
        #expect(apdu?.isSegmented == true)
        guard case .segmented(productID: 63)? = apdu?.decodeProduct() else {
            Issue.record("Expected segmented product")
            return
        }
    }

    @Test func unknownProductIsUnhandled() {
        let body = FISBEncoding.apdu(productID: 103, hours: 0, minutes: 0, payload: [0x01])
        guard case .unhandled(productID: 103)? = FISBAPDU.parse(body)?.decodeProduct() else {
            Issue.record("Expected unhandled product")
            return
        }
    }

    /// Product 8 carries NOTAMs in the same DLAC records as product 413.
    @Test func notamProductDecodesAsText() {
        let text = "NOTAM-D KAUS 01/005 TWY A CLSD\u{1E}NOTAM-FDC KAUS 1/2345 SPECIAL NOTICE"
        let body = FISBEncoding.apdu(productID: 8, hours: 19, minutes: 53, payload: DLAC.encode(text))
        guard case .text(let reports)? = FISBAPDU.parse(body)?.decodeProduct() else {
            Issue.record("Expected product 8 to decode as text")
            return
        }
        #expect(reports.count == 2)
        #expect(reports.filter { $0.kind.isNotam }.count == 2)
        #expect(reports.first?.kind == .notamD)
        #expect(reports.first?.station == "KAUS")
        #expect(reports.last?.kind == .notamFDC)
    }

    @Test func tooShortBodyReturnsNil() {
        #expect(FISBAPDU.parse([0x06, 0x75, 0x3B]) == nil)
    }
}

@Suite struct FISBTextReportTests {
    @Test func classifiesRecordKinds() {
        let payload = DLAC.encode(
            "METAR KAUS 151953Z 18010KT\u{1E}SPECI KDAL 152007Z\u{1E}TAF KHOU 151740Z"
            + "\u{1E}TAF.AMD KOKC 152015Z\u{1E}PIREP AUS UA /OV KAUS\u{1E}WINDS DAL FT 3000 6000"
        )
        let reports = FISBTextReport.reports(fromDLACPayload: payload)
        #expect(reports.map(\.kind) == [.metar, .speci, .taf, .tafAmendment, .pirep, .windsAloft])
        #expect(reports.map(\.station) == ["KAUS", "KDAL", "KHOU", "KOKC", "AUS", "DAL"])
        #expect(reports[0].text == "KAUS 151953Z 18010KT")
    }

    @Test func unknownLeadingTokenIsOther() {
        let reports = FISBTextReport.reports(fromDLACPayload: DLAC.encode("NOSUCH KAUS THING"))
        #expect(reports.count == 1)
        #expect(reports[0].kind == .other)
        #expect(reports[0].station == "NOSUCH")
        #expect(reports[0].text == "NOSUCH KAUS THING")
    }

    @Test func skipsEmptyRecordsAndTrailingETX() {
        let payload = DLAC.encode("METAR KAUS 151953Z\u{1E}\u{1E}")
        let reports = FISBTextReport.reports(fromDLACPayload: payload)
        #expect(reports.count == 1)
    }
}

@Suite struct NEXRADTests {
    @Test func decodesRLEBlock() {
        // Four full runs (32 bins each) of intensity 2: byte 0xFA × 4.
        let payload: [UInt8] = [0x80, 0x00, 0x2A, 0xFA, 0xFA, 0xFA, 0xFA]
        let product = NEXRADGlobalBlock.decode(payload: payload, scope: .regional)
        #expect(product?.blocks.count == 1)
        #expect(product?.blocks.first?.blockNumber == 42)
        #expect(product?.blocks.first?.scaleFactor == 0)
        #expect(product?.blocks.first?.intensities == [UInt8](repeating: 2, count: 128))
    }

    @Test func rleRoundTripsThroughEncoder() {
        var bins = [UInt8](repeating: 0, count: 128)
        for i in 40..<60 { bins[i] = UInt8(2 + i % 5) }
        guard let payload = FISBEncoding.nexradRLE(blockNumber: 204_627, scaleFactor: 0, intensities: bins) else {
            Issue.record("Encoder rejected valid bins")
            return
        }
        let product = NEXRADGlobalBlock.decode(payload: payload, scope: .regional)
        #expect(product?.blocks.first?.intensities == bins)
        #expect(product?.blocks.first?.blockNumber == 204_627)
    }

    @Test func rleOverflowReturnsNil() {
        // Five full runs = 160 bins > 128.
        let payload: [UInt8] = [0x80, 0x00, 0x2A, 0xFA, 0xFA, 0xFA, 0xFA, 0xFA]
        #expect(NEXRADGlobalBlock.decode(payload: payload, scope: .regional) == nil)
    }

    @Test func rleUnderflowReturnsNil() {
        let payload: [UInt8] = [0x80, 0x00, 0x2A, 0xFA]
        #expect(NEXRADGlobalBlock.decode(payload: payload, scope: .regional) == nil)
    }

    @Test func decodesEmptyBlockBitmap() {
        // Block 1000; byte 3 = len 2 + bits for +1/+4; byte 4 = bits for +5/+12.
        let payload: [UInt8] = [0x00, 0x03, 0xE8, 0x92, 0x81]
        let product = NEXRADGlobalBlock.decode(payload: payload, scope: .conus)
        #expect(product?.blocks.isEmpty == true)
        #expect(product?.clearedBlocks == [1000, 1001, 1004, 1005, 1012])
    }

    @Test func truncatedPayloadsNeverCrash() {
        let payload: [UInt8] = [0x80, 0x00, 0x2A, 0xFA, 0xFA, 0xFA, 0xFA]
        for length in 0..<payload.count {
            _ = NEXRADGlobalBlock.decode(payload: Array(payload.prefix(length)), scope: .regional)
        }
    }
}

@Suite struct NEXRADGeometryTests {
    @Test func blockZeroStartsAtOriginAtScaleZero() {
        let bounds = NEXRADBlockGeometry.bounds(blockNumber: 0, scaleFactor: 0)
        #expect(bounds == .init(south: 0, west: 0, north: 4.0 / 60, east: 48.0 / 60))
    }

    @Test func secondRowStartsAtBlock450() {
        let bounds = NEXRADBlockGeometry.bounds(blockNumber: 450, scaleFactor: 0)
        #expect(bounds?.south == 4.0 / 60)
        #expect(bounds?.west == 0)
    }

    @Test func austinBlockMapsToAustin() {
        // Row 454, column 327 → block 204627 ≈ 30.27°N 98.4°W.
        guard let bounds = NEXRADBlockGeometry.bounds(blockNumber: 204_627, scaleFactor: 0) else {
            Issue.record("Expected bounds")
            return
        }
        #expect(abs(bounds.south - 30.2667) < 0.001)
        #expect(abs(bounds.west - -98.4) < 0.001)
        #expect(abs(bounds.north - bounds.south - 4.0 / 60) < 1e-9)
    }

    @Test func conusScaleOneBlocksAreFiveTimesLarger() {
        // 90 blocks per row: block 90 starts row 1.
        let bounds = NEXRADBlockGeometry.bounds(blockNumber: 90, scaleFactor: 1)
        #expect(bounds?.south == 20.0 / 60)
        #expect(bounds?.west == 0)
        #expect(bounds?.east == 240.0 / 60)
    }

    @Test func highLatitudeBlocksAreDoubleWidth() {
        let first = NEXRADBlockGeometry.bounds(blockNumber: 405_000, scaleFactor: 0)
        #expect(first?.south == 60)
        #expect(first?.west == 0)
        #expect(first?.east == 96.0 / 60)
        let second = NEXRADBlockGeometry.bounds(blockNumber: 405_002, scaleFactor: 0)
        #expect(second?.west == 96.0 / 60)
    }

    @Test func binZeroIsNorthwestCorner() {
        guard let block = NEXRADBlockGeometry.bounds(blockNumber: 204_627, scaleFactor: 0),
              let bin = NEXRADBlockGeometry.binBounds(blockNumber: 204_627, scaleFactor: 0, binIndex: 0) else {
            Issue.record("Expected bounds")
            return
        }
        #expect(bin.north == block.north)
        #expect(bin.west == block.west)
        #expect(abs(bin.north - bin.south - 1.0 / 60) < 1e-9)
        #expect(abs(bin.east - bin.west - 1.5 / 60) < 1e-9)
    }

    @Test func invalidScaleFactorReturnsNil() {
        #expect(NEXRADBlockGeometry.bounds(blockNumber: 0, scaleFactor: 3) == nil)
        #expect(NEXRADBlockGeometry.binBounds(blockNumber: 0, scaleFactor: 0, binIndex: 128) == nil)
    }
}

@Suite struct EndToEndTests {
    @Test func fullUplinkFrameDecodesToProducts() {
        var bins = [UInt8](repeating: 0, count: 128)
        bins[65] = 6
        guard let radarPayload = FISBEncoding.nexradRLE(blockNumber: 204_627, scaleFactor: 0, intensities: bins) else {
            Issue.record("Encoder rejected valid bins")
            return
        }
        let frame = FISBEncoding.uplinkFrame(infoFrames: [
            FISBEncoding.infoFrame(body: FISBEncoding.apdu(
                productID: 413, hours: 19, minutes: 53,
                payload: DLAC.encode("METAR KAUS 151953Z 18010KT")
            )),
            FISBEncoding.infoFrame(body: FISBEncoding.apdu(
                productID: 63, hours: 19, minutes: 55, payload: radarPayload
            )),
        ])

        guard let parsed = UATUplinkFrame.parse(frame) else {
            Issue.record("Expected parsed frame")
            return
        }
        #expect(parsed.apdus.count == 2)

        guard case .text(let reports) = parsed.apdus[0].decodeProduct() else {
            Issue.record("Expected text product")
            return
        }
        #expect(reports == [FISBTextReport(kind: .metar, station: "KAUS", text: "KAUS 151953Z 18010KT")])

        guard case .nexrad(let radar) = parsed.apdus[1].decodeProduct() else {
            Issue.record("Expected NEXRAD product")
            return
        }
        #expect(radar.scope == .regional)
        #expect(radar.blocks.first?.intensities[65] == 6)
    }
}
