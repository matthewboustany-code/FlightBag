import Foundation

/// GDL90 datalink framing (GDL90 spec §2.2): messages are wrapped in 0x7E
/// flag bytes, byte-stuffed with 0x7D XOR 0x20, and carry a trailing
/// CRC-16-CCITT (LSB first). This type is a pure byte machine — feed it UDP
/// datagram payloads, get verified message payloads out — so it unit-tests
/// against captured receiver traffic with no sockets involved.
public struct GDL90Deframer: Sendable {
    public static let flagByte: UInt8 = 0x7E
    public static let controlEscape: UInt8 = 0x7D

    private var buffer: [UInt8] = []
    private var inFrame = false

    public init() {}

    /// Feed raw bytes; returns any complete, CRC-valid message payloads
    /// (message ID byte included, framing and CRC stripped).
    public mutating func feed(_ data: some Sequence<UInt8>) -> [[UInt8]] {
        var messages: [[UInt8]] = []
        for byte in data {
            if byte == Self.flagByte {
                if inFrame, !buffer.isEmpty {
                    if let payload = Self.unwrap(buffer) {
                        messages.append(payload)
                    }
                    buffer.removeAll(keepingCapacity: true)
                }
                inFrame = true
                continue
            }
            if inFrame {
                buffer.append(byte)
            }
        }
        return messages
    }

    /// Unstuff and CRC-check the bytes between two flags.
    private static func unwrap(_ stuffed: [UInt8]) -> [UInt8]? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(stuffed.count)
        var escaping = false
        for byte in stuffed {
            if escaping {
                bytes.append(byte ^ 0x20)
                escaping = false
            } else if byte == controlEscape {
                escaping = true
            } else {
                bytes.append(byte)
            }
        }
        guard !escaping, bytes.count >= 3 else { return nil }
        let payload = Array(bytes.dropLast(2))
        let receivedCRC = UInt16(bytes[bytes.count - 2]) | (UInt16(bytes[bytes.count - 1]) << 8)
        guard crc16(payload) == receivedCRC else { return nil }
        return payload
    }

    /// CRC-16-CCITT as specified in GDL90 §2.2.3.
    public static func crc16(_ bytes: some Sequence<UInt8>) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc = crcTable[Int(crc >> 8)] ^ (crc << 8) ^ UInt16(byte)
        }
        return crc
    }

    static let crcTable: [UInt16] = (0..<256).map { i in
        var crc = UInt16(i) << 8
        for _ in 0..<8 {
            crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
        }
        return crc
    }

    /// Build a complete frame (flags, stuffing, CRC) around a payload —
    /// used by tests and simulators.
    public static func frame(_ payload: [UInt8]) -> [UInt8] {
        let crc = crc16(payload)
        var body = payload
        body.append(UInt8(crc & 0xFF))
        body.append(UInt8(crc >> 8))
        var framed: [UInt8] = [flagByte]
        for byte in body {
            if byte == flagByte || byte == controlEscape {
                framed.append(controlEscape)
                framed.append(byte ^ 0x20)
            } else {
                framed.append(byte)
            }
        }
        framed.append(flagByte)
        return framed
    }
}
