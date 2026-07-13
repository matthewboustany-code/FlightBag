import Foundation
import Testing
@testable import FBGDL90

@Suite struct GDL90DeframerTests {
    @Test func crcMatchesSpecExample() {
        // GDL90 spec §2.2.4 example: heartbeat message 00 81 41 DB D0 08 02
        // has CRC bytes B3 8B (LSB first).
        let payload: [UInt8] = [0x00, 0x81, 0x41, 0xDB, 0xD0, 0x08, 0x02]
        let crc = GDL90Deframer.crc16(payload)
        #expect(UInt8(crc & 0xFF) == 0xB3)
        #expect(UInt8(crc >> 8) == 0x8B)
    }

    @Test func roundTripsFramedMessage() {
        let payload: [UInt8] = [0x00, 0x81, 0x41, 0xDB, 0xD0, 0x08, 0x02]
        var deframer = GDL90Deframer()
        let messages = deframer.feed(GDL90Deframer.frame(payload))
        #expect(messages == [payload])
    }

    @Test func byteStuffingRoundTrip() {
        // Payload containing both the flag and escape bytes must be stuffed.
        let payload: [UInt8] = [0x14, 0x7E, 0x7D, 0x00, 0xFF]
        let framed = GDL90Deframer.frame(payload)
        // No unescaped flag bytes inside the frame body.
        #expect(framed.dropFirst().dropLast().allSatisfy { $0 != 0x7E })
        var deframer = GDL90Deframer()
        #expect(deframer.feed(framed) == [payload])
    }

    @Test func rejectsCorruptedCRC() {
        var framed = GDL90Deframer.frame([0x00, 0x81, 0x41, 0xDB, 0xD0, 0x08, 0x02])
        framed[2] ^= 0xFF
        var deframer = GDL90Deframer()
        #expect(deframer.feed(framed).isEmpty)
    }

    @Test func handlesMessagesSplitAcrossFeeds() {
        let payload: [UInt8] = [0x00, 0x81, 0x41, 0xDB, 0xD0, 0x08, 0x02]
        let framed = GDL90Deframer.frame(payload)
        var deframer = GDL90Deframer()
        let first = deframer.feed(framed.prefix(4))
        #expect(first.isEmpty)
        let second = deframer.feed(framed.dropFirst(4))
        #expect(second == [payload])
    }
}

@Suite struct GDL90MessageTests {
    @Test func decodesHeartbeat() {
        let payload: [UInt8] = [0x00, 0x81, 0x41, 0xDB, 0xD0, 0x08, 0x02]
        let message = GDL90Message.decode(payload)
        guard case .heartbeat(let heartbeat) = message else {
            Issue.record("Expected heartbeat, got \(String(describing: message))")
            return
        }
        #expect(heartbeat.gpsPositionValid)
        #expect(heartbeat.utcTimingValid)
    }

    /// Traffic report example from GDL90 spec §3.5.2: ICAO address 52642511 (octal),
    /// 44.90708°N 122.99488°W, 5,000 ft, airborne, 123 kt, 64 fpm climb,
    /// track 45°, category light, callsign N825V.
    @Test func decodesSpecTrafficReport() {
        let payload: [UInt8] = [
            0x14,
            0x00, 0xAB, 0x45, 0x49, 0x1F, 0xEF, 0x15, 0xA8, 0x89, 0x78,
            0x0F, 0x09, 0xA9, 0x07, 0xB0, 0x01, 0x20, 0x01,
            0x4E, 0x38, 0x32, 0x35, 0x56, 0x20, 0x20, 0x20, 0x00,
        ]
        let message = GDL90Message.decode(payload)
        guard case .trafficReport(let traffic) = message else {
            Issue.record("Expected traffic report, got \(String(describing: message))")
            return
        }
        #expect(!traffic.alert)
        #expect(traffic.addressType == .adsbICAO)
        #expect(abs(traffic.latitude - 44.90708) < 0.0001)
        #expect(abs(traffic.longitude - -122.99488) < 0.0001)
        #expect(traffic.altitudeFeet == 5000)
        #expect(traffic.airborne)
        #expect(traffic.groundSpeedKt == 123)
        #expect(traffic.verticalVelocityFpm == 64)
        #expect(abs(traffic.trackDegrees - 45) < 1.5)
        #expect(traffic.callsign == "N825V")
    }

    @Test func decodesOwnshipGeoAltitude() {
        // 0x0B, altitude in 5 ft units: 1000 ft = 200 = 0x00C8.
        let message = GDL90Message.decode([0x0B, 0x00, 0xC8, 0x00, 0x00])
        guard case .ownshipGeometricAltitude(let feet) = message else {
            Issue.record("Expected geo altitude, got \(String(describing: message))")
            return
        }
        #expect(feet == 1000)
    }

    @Test func invalidFieldsDecodeAsNil() {
        var payload: [UInt8] = [0x14]
        payload += [0x00, 0x00, 0x00, 0x01]          // address
        payload += [0x00, 0x00, 0x00, 0x00, 0x00, 0x00]  // lat/lon 0
        payload += [0xFF, 0xF8]                      // altitude invalid (0xFFF), airborne
        payload += [0x00]                            // NIC/NACp
        payload += [0xFF, 0xF8, 0x00]                // hVel invalid, vVel 0x800 invalid
        payload += [0x00, 0x01]                      // track, emitter
        payload += Array("N0      ".utf8)            // callsign
        payload += [0x00]                            // priority
        guard case .trafficReport(let traffic)? = GDL90Message.decode(payload) else {
            Issue.record("Expected traffic report")
            return
        }
        #expect(traffic.altitudeFeet == nil)
        #expect(traffic.groundSpeedKt == nil)
        #expect(traffic.verticalVelocityFpm == nil)
    }
}
