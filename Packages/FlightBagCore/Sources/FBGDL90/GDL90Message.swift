import Foundation

/// Decoded GDL90 messages (GDL90 spec, plus the ForeFlight 0x65 extension
/// implemented by Stratux/Sentry). Input is a deframed, CRC-verified payload
/// from `GDL90Deframer`.
public enum GDL90Message: Sendable, Hashable {
    case heartbeat(Heartbeat)
    case ownship(TrafficReport)
    case ownshipGeometricAltitude(feet: Int)
    case trafficReport(TrafficReport)
    /// FIS-B uplink payload (UAT frame); product decoding is a later layer.
    case uplinkData([UInt8])
    case foreFlightAHRS(AHRS)
    case unknown(id: UInt8)

    public static func decode(_ payload: [UInt8]) -> GDL90Message? {
        guard let id = payload.first else { return nil }
        switch id {
        case 0x00:
            return Heartbeat(payload: payload).map { .heartbeat($0) }
        case 0x07:
            // 3 header bytes (ID + time of reception) precede the UAT frame.
            guard payload.count > 4 else { return nil }
            return .uplinkData(Array(payload.dropFirst(4)))
        case 0x0A:
            return TrafficReport(payload: payload).map { .ownship($0) }
        case 0x0B:
            guard payload.count >= 3 else { return nil }
            let raw = Int16(bitPattern: UInt16(payload[1]) << 8 | UInt16(payload[2]))
            return .ownshipGeometricAltitude(feet: Int(raw) * 5)
        case 0x14:
            return TrafficReport(payload: payload).map { .trafficReport($0) }
        case 0x65:
            return AHRS(payload: payload).map { .foreFlightAHRS($0) }
        default:
            return .unknown(id: id)
        }
    }

    public struct Heartbeat: Sendable, Hashable {
        public let gpsPositionValid: Bool
        public let utcTimingValid: Bool
        /// Seconds since UTC midnight.
        public let timestamp: UInt32

        init?(payload: [UInt8]) {
            guard payload.count >= 7 else { return nil }
            let status1 = payload[1]
            let status2 = payload[2]
            gpsPositionValid = (status1 & 0x80) != 0
            utcTimingValid = (status1 & 0x01) != 0
            // 17-bit timestamp: bit 16 lives in status2 bit 7; bytes are LSB first.
            let ts16 = UInt32(payload[3]) | (UInt32(payload[4]) << 8)
            let bit16 = UInt32((status2 & 0x80) >> 7) << 16
            timestamp = ts16 | bit16
        }
    }

    /// Ownship (0x0A) and traffic (0x14) share this 27-byte report layout
    /// (GDL90 §3.5.1).
    public struct TrafficReport: Sendable, Hashable {
        public enum AddressType: UInt8, Sendable {
            case adsbICAO = 0
            case adsbSelfAssigned = 1
            case tisbICAO = 2
            case tisbTrackFile = 3
            case surface = 4
            case groundBeacon = 5
        }

        public let alert: Bool
        public let addressType: AddressType?
        /// 24-bit participant address (ICAO Mode S address for type 0).
        public let address: UInt32
        public let latitude: Double
        public let longitude: Double
        /// Pressure altitude, ft; nil when invalid (0xFFF).
        public let altitudeFeet: Int?
        public let airborne: Bool
        /// Navigation Integrity Category (0 = unknown/no fix, 11 = best).
        public let nic: Int
        /// Navigation Accuracy Category for Position.
        public let nacp: Int
        /// True track or heading, degrees.
        public let trackDegrees: Double
        /// Ground speed, kt; nil when invalid.
        public let groundSpeedKt: Int?
        /// Vertical velocity, fpm; nil when invalid.
        public let verticalVelocityFpm: Int?
        public let emitterCategory: UInt8
        public let callsign: String

        /// Memberwise init for synthesizing reports (demos, tests).
        public init(
            alert: Bool = false,
            addressType: AddressType? = .adsbICAO,
            address: UInt32,
            latitude: Double,
            longitude: Double,
            altitudeFeet: Int?,
            airborne: Bool = true,
            nic: Int = 10,
            nacp: Int = 9,
            trackDegrees: Double = 0,
            groundSpeedKt: Int? = nil,
            verticalVelocityFpm: Int? = nil,
            emitterCategory: UInt8 = 1,
            callsign: String = ""
        ) {
            self.alert = alert
            self.addressType = addressType
            self.address = address
            self.latitude = latitude
            self.longitude = longitude
            self.altitudeFeet = altitudeFeet
            self.airborne = airborne
            self.nic = nic
            self.nacp = nacp
            self.trackDegrees = trackDegrees
            self.groundSpeedKt = groundSpeedKt
            self.verticalVelocityFpm = verticalVelocityFpm
            self.emitterCategory = emitterCategory
            self.callsign = callsign
        }

        init?(payload: [UInt8]) {
            guard payload.count >= 28 else { return nil }
            let b = Array(payload.dropFirst())  // 27 report bytes
            alert = (b[0] >> 4) == 1
            addressType = AddressType(rawValue: b[0] & 0x0F)
            address = UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
            latitude = Self.semicircles(b[4], b[5], b[6])
            longitude = Self.semicircles(b[7], b[8], b[9])

            let altBits = (UInt16(b[10]) << 4) | (UInt16(b[11]) >> 4)
            altitudeFeet = altBits == 0xFFF ? nil : Int(altBits) * 25 - 1000

            let misc = b[11] & 0x0F
            airborne = (misc & 0x08) != 0

            nic = Int(b[12] >> 4)
            nacp = Int(b[12] & 0x0F)

            let hVel = (UInt16(b[13]) << 4) | (UInt16(b[14]) >> 4)
            groundSpeedKt = hVel == 0xFFF ? nil : Int(hVel)

            let vVelBits = (UInt16(b[14] & 0x0F) << 8) | UInt16(b[15])
            if vVelBits == 0x800 {
                verticalVelocityFpm = nil
            } else {
                // 12-bit signed, units of 64 fpm.
                let signed = vVelBits > 0x7FF ? Int(vVelBits) - 4096 : Int(vVelBits)
                verticalVelocityFpm = signed * 64
            }

            trackDegrees = Double(b[16]) * 360.0 / 256.0
            emitterCategory = b[17]
            let callsignBytes = b[18..<26].filter { $0 != 0x20 && $0 != 0x00 }
            callsign = String(bytes: callsignBytes, encoding: .ascii) ?? ""
        }

        /// 24-bit two's-complement semicircle to degrees (180 / 2^23).
        static func semicircles(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8) -> Double {
            var value = Int32(b0) << 16 | Int32(b1) << 8 | Int32(b2)
            if value > 0x7FFFFF { value -= 0x1000000 }
            return Double(value) * (180.0 / 8_388_608.0)
        }
    }

    /// ForeFlight extension message 0x65, sub-id 0x01 (AHRS), sent by
    /// Stratux/Sentry at 5 Hz.
    public struct AHRS: Sendable, Hashable {
        /// Degrees; positive = right wing down. Nil when invalid (0x7FFF).
        public let rollDegrees: Double?
        /// Degrees; positive = nose up.
        public let pitchDegrees: Double?
        /// Degrees, true or magnetic per source flag.
        public let headingDegrees: Double?
        public let indicatedAirspeedKt: Int?
        public let trueAirspeedKt: Int?

        init?(payload: [UInt8]) {
            guard payload.count >= 12, payload[1] == 0x01 else { return nil }
            let b = payload
            func signed16(_ hi: UInt8, _ lo: UInt8) -> Int16 { Int16(bitPattern: UInt16(hi) << 8 | UInt16(lo)) }
            let roll = signed16(b[2], b[3])
            let pitch = signed16(b[4], b[5])
            let heading = signed16(b[6], b[7])
            rollDegrees = roll == 0x7FFF ? nil : Double(roll) / 10.0
            pitchDegrees = pitch == 0x7FFF ? nil : Double(pitch) / 10.0
            headingDegrees = heading == 0x7FFF ? nil : Double(heading & 0x7FFF) / 10.0
            let ias = UInt16(b[8]) << 8 | UInt16(b[9])
            let tas = UInt16(b[10]) << 8 | UInt16(b[11])
            indicatedAirspeedKt = ias == 0xFFFF ? nil : Int(ias)
            trueAirspeedKt = tas == 0xFFFF ? nil : Int(tas)
        }
    }
}
