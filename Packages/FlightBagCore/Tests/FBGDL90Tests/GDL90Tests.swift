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
        #expect(traffic.nic == 10)
        #expect(traffic.nacp == 9)
    }

    @Test func decodesOwnshipReport() {
        // Same 27-byte layout as traffic, message ID 0x0A → .ownship.
        var payload: [UInt8] = [
            0x00, 0xAB, 0x45, 0x49, 0x1F, 0xEF, 0x15, 0xA8, 0x89, 0x78,
            0x0F, 0x09, 0xA9, 0x07, 0xB0, 0x01, 0x20, 0x01,
            0x4E, 0x38, 0x32, 0x35, 0x56, 0x20, 0x20, 0x20, 0x00,
        ]
        payload.insert(0x0A, at: 0)
        guard case .ownship(let ownship)? = GDL90Message.decode(payload) else {
            Issue.record("Expected ownship report")
            return
        }
        #expect(abs(ownship.latitude - 44.90708) < 0.0001)
        #expect(ownship.nic == 10)
    }

    @Test func ownshipNoFixReportsZeroPositionAndNIC() {
        // A receiver without GPS lock emits lat/lon 0 with NIC 0; the app
        // must be able to detect and reject this via nic.
        var payload: [UInt8] = [0x0A]
        payload += [0x00, 0x00, 0x00, 0x01]              // address
        payload += [0x00, 0x00, 0x00, 0x00, 0x00, 0x00]  // lat/lon 0
        payload += [0xFF, 0xF0]                          // altitude invalid, on ground
        payload += [0x00]                                // NIC 0 / NACp 0
        payload += [0xFF, 0xF8, 0x00]                    // hVel/vVel invalid
        payload += [0x00, 0x01]                          // track, emitter
        payload += Array("        ".utf8)                // callsign
        payload += [0x00]                                // priority
        guard case .ownship(let ownship)? = GDL90Message.decode(payload) else {
            Issue.record("Expected ownship report")
            return
        }
        #expect(ownship.latitude == 0)
        #expect(ownship.longitude == 0)
        #expect(ownship.nic == 0)
        #expect(!ownship.airborne)
    }

    @Test func decodesNegativeGeoAltitude() {
        // -1000 ft = -200 in 5 ft units = 0xFF38 big-endian.
        let message = GDL90Message.decode([0x0B, 0xFF, 0x38, 0x00, 0x00])
        guard case .ownshipGeometricAltitude(let feet)? = message else {
            Issue.record("Expected geo altitude, got \(String(describing: message))")
            return
        }
        #expect(feet == -1000)
    }

    @Test func uplinkDataDropsHeaderBytes() {
        // 0x07 + 3 time-of-reception bytes precede the UAT frame.
        let uatFrame: [UInt8] = [0xAA, 0xBB, 0xCC, 0xDD, 0xEE]
        let payload: [UInt8] = [0x07, 0x01, 0x02, 0x03] + uatFrame
        guard case .uplinkData(let frame)? = GDL90Message.decode(payload) else {
            Issue.record("Expected uplink data")
            return
        }
        #expect(frame == uatFrame)
    }

    @Test func tooShortUplinkReturnsNil() {
        #expect(GDL90Message.decode([0x07, 0x01, 0x02, 0x03]) == nil)
    }

    @Test func decodesForeFlightAHRS() {
        // Roll +10.5° = 105, pitch -5.0° = -50 = 0xFFCE, heading 270.0° = 2700,
        // IAS 100 kt, TAS 110 kt. All big-endian signed16 in tenths.
        let payload: [UInt8] = [
            0x65, 0x01,
            0x00, 0x69,  // roll
            0xFF, 0xCE,  // pitch
            0x0A, 0x8C,  // heading
            0x00, 0x64,  // IAS
            0x00, 0x6E,  // TAS
        ]
        guard case .foreFlightAHRS(let ahrs)? = GDL90Message.decode(payload) else {
            Issue.record("Expected AHRS")
            return
        }
        #expect(ahrs.rollDegrees == 10.5)
        #expect(ahrs.pitchDegrees == -5.0)
        #expect(ahrs.headingDegrees == 270.0)
        #expect(ahrs.indicatedAirspeedKt == 100)
        #expect(ahrs.trueAirspeedKt == 110)
    }

    @Test func ahrsInvalidFieldsDecodeAsNil() {
        let payload: [UInt8] = [
            0x65, 0x01,
            0x7F, 0xFF,  // roll invalid
            0x7F, 0xFF,  // pitch invalid
            0x7F, 0xFF,  // heading invalid
            0xFF, 0xFF,  // IAS invalid
            0xFF, 0xFF,  // TAS invalid
        ]
        guard case .foreFlightAHRS(let ahrs)? = GDL90Message.decode(payload) else {
            Issue.record("Expected AHRS")
            return
        }
        #expect(ahrs.rollDegrees == nil)
        #expect(ahrs.pitchDegrees == nil)
        #expect(ahrs.headingDegrees == nil)
        #expect(ahrs.indicatedAirspeedKt == nil)
        #expect(ahrs.trueAirspeedKt == nil)
    }

    @Test func ahrsWrongSubIDReturnsNil() {
        let payload: [UInt8] = [0x65, 0x00] + [UInt8](repeating: 0, count: 10)
        #expect(GDL90Message.decode(payload) == nil)
    }

    @Test func heartbeatTimestampUsesBit16FromStatus2() {
        // status2 bit 7 carries timestamp bit 16; bytes 3-4 are LSB-first.
        // ts16 = 0x8000, bit16 set → 0x18000 = 98304 s (> 24h wrap is the
        // sender's problem; we decode the raw field).
        let payload: [UInt8] = [0x00, 0x81, 0x80, 0x00, 0x80, 0x08, 0x02]
        guard case .heartbeat(let heartbeat)? = GDL90Message.decode(payload) else {
            Issue.record("Expected heartbeat")
            return
        }
        #expect(heartbeat.timestamp == 0x18000)
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
