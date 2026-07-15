import Foundation

/// Builders for synthesizing FIS-B uplink data — the encode direction is
/// only exercised by tests and the gdl90sim tool, keeping the decoders
/// honest via round-trips.
public enum FISBEncoding {
    /// RLE-encodes 128 bins into a product 63/64 APDU payload.
    public static func nexradRLE(blockNumber: Int, scaleFactor: Int, intensities: [UInt8]) -> [UInt8]? {
        guard intensities.count == NEXRADGlobalBlock.binsPerBlock,
              intensities.allSatisfy({ $0 <= 7 }),
              scaleFactor >= 0 && scaleFactor <= 2,
              blockNumber >= 0 && blockNumber < (1 << 20) else { return nil }
        var payload: [UInt8] = [
            0x80 | UInt8(scaleFactor) << 4 | UInt8(blockNumber >> 16),
            UInt8((blockNumber >> 8) & 0xFF),
            UInt8(blockNumber & 0xFF),
        ]
        var index = 0
        while index < intensities.count {
            let intensity = intensities[index]
            var run = 1
            while run < 32 && index + run < intensities.count && intensities[index + run] == intensity {
                run += 1
            }
            payload.append(UInt8(run - 1) << 3 | intensity)
            index += run
        }
        return payload
    }

    /// Wraps a product payload in an APDU header (time option 0:
    /// hours + minutes, unsegmented).
    public static func apdu(productID: Int, hours: Int, minutes: Int, payload: [UInt8]) -> [UInt8] {
        var apdu: [UInt8] = [
            UInt8((productID >> 6) & 0x1F),
            UInt8((productID & 0x3F) << 2),
            UInt8((hours & 0x1F) << 2 | (minutes >> 4) & 0x03),
            UInt8((minutes & 0x0F) << 4),
        ]
        apdu.append(contentsOf: payload)
        return apdu
    }

    /// Wraps a body in an information-frame header (9-bit length, 4-bit
    /// type).
    public static func infoFrame(type: UInt8 = 0, body: [UInt8]) -> [UInt8] {
        precondition(body.count < 512, "info frame body exceeds 9-bit length")
        var frame: [UInt8] = [
            UInt8(body.count >> 1),
            UInt8((body.count & 0x01) << 7) | (type & 0x0F),
        ]
        frame.append(contentsOf: body)
        return frame
    }

    /// Assembles a full 432-byte UAT ground uplink frame from information
    /// frames, zero-padding the 424-byte application data area.
    public static func uplinkFrame(infoFrames: [[UInt8]]) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: 8)
        header[6] = 0x20  // application data valid
        var applicationData = infoFrames.flatMap { $0 }
        precondition(applicationData.count <= 424, "application data exceeds 424 bytes")
        applicationData.append(contentsOf: repeatElement(0, count: 424 - applicationData.count))
        return header + applicationData
    }
}
