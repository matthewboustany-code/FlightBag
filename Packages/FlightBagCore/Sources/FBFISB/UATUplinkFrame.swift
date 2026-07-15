import Foundation

/// A UAT ground uplink frame: 8-byte header + up to 424 bytes of
/// application data holding length-prefixed information frames. This is
/// the payload delivered by GDL90 message 0x07 (after its own header).
public struct UATUplinkFrame: Sendable {
    /// Ground station position; nil when the frame's position-valid bit
    /// is clear.
    public let siteLatitude: Double?
    public let siteLongitude: Double?
    public let applicationDataValid: Bool
    public let slotID: Int
    public let tisbSiteID: Int
    /// FIS-B APDUs extracted from type-0 information frames.
    public let apdus: [FISBAPDU]
    /// Types of non-APDU information frames encountered (skipped).
    public let skippedFrameTypes: [Int]

    private static let applicationDataLength = 424

    public static func parse(_ frame: [UInt8]) -> UATUplinkFrame? {
        guard frame.count >= 8 else { return nil }

        let positionValid = frame[5] & 0x01 != 0
        var latitude: Double?
        var longitude: Double?
        if positionValid {
            let rawLat = UInt32(frame[0]) << 15 | UInt32(frame[1]) << 7 | UInt32(frame[2]) >> 1
            let rawLon = UInt32(frame[2] & 0x01) << 23 | UInt32(frame[3]) << 15
                | UInt32(frame[4]) << 7 | UInt32(frame[5]) >> 1
            var lat = Double(rawLat) * 360.0 / 16_777_216.0
            if lat > 90 { lat -= 180 }
            var lon = Double(rawLon) * 360.0 / 16_777_216.0
            if lon > 180 { lon -= 360 }
            latitude = lat
            longitude = lon
        }

        let applicationDataValid = frame[6] & 0x20 != 0
        let slotID = Int(frame[6] & 0x1F)
        let tisbSiteID = Int(frame[7] >> 4)

        var apdus: [FISBAPDU] = []
        var skipped: [Int] = []
        if applicationDataValid {
            let data = Array(frame.dropFirst(8).prefix(applicationDataLength))
            var pos = 0
            // Each information frame: 9-bit length, 4-bit type, then body.
            // A zero length with type 0 terminates the list.
            while pos + 2 <= data.count {
                let length = Int(data[pos]) << 1 | Int(data[pos + 1]) >> 7
                let type = Int(data[pos + 1] & 0x0F)
                if pos + 2 + length > data.count { break }
                if length == 0 && type == 0 { break }
                let body = Array(data[(pos + 2)..<(pos + 2 + length)])
                if type == 0 {
                    if let apdu = FISBAPDU.parse(body) { apdus.append(apdu) }
                } else {
                    skipped.append(type)
                }
                pos += length + 2
            }
        }

        return UATUplinkFrame(
            siteLatitude: latitude,
            siteLongitude: longitude,
            applicationDataValid: applicationDataValid,
            slotID: slotID,
            tisbSiteID: tisbSiteID,
            apdus: apdus,
            skippedFrameTypes: skipped
        )
    }
}
