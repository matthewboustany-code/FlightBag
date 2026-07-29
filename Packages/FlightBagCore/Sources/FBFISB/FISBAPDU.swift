import Foundation

/// One FIS-B Application Protocol Data Unit from a type-0 information
/// frame: header (flags, 11-bit product ID, broadcast time) + payload.
public struct FISBAPDU: Sendable {
    public let productID: Int
    public let isSegmented: Bool
    /// Broadcast time; month/day and seconds are present only for some
    /// time options.
    public let month: Int?
    public let day: Int?
    public let hours: Int
    public let minutes: Int
    public let seconds: Int?
    public let payload: [UInt8]

    public static func parse(_ body: [UInt8]) -> FISBAPDU? {
        guard body.count >= 4 else { return nil }
        let productID = Int(body[0] & 0x1F) << 6 | Int(body[1] >> 2)
        let isSegmented = body[1] & 0x02 != 0
        let timeOption = Int(body[1] & 0x01) << 1 | Int(body[2] >> 7)

        var month: Int?
        var day: Int?
        let hours: Int
        let minutes: Int
        var seconds: Int?
        let headerLength: Int

        switch timeOption {
        case 0:  // hours, minutes
            hours = Int(body[2] & 0x7C) >> 2
            minutes = Int(body[2] & 0x03) << 4 | Int(body[3] >> 4)
            headerLength = 4
        case 1:  // hours, minutes, seconds
            guard body.count >= 5 else { return nil }
            hours = Int(body[2] & 0x7C) >> 2
            minutes = Int(body[2] & 0x03) << 4 | Int(body[3] >> 4)
            seconds = Int(body[3] & 0x0F) << 2 | Int(body[4] >> 6)
            headerLength = 5
        case 2:  // month, day, hours, minutes
            guard body.count >= 5 else { return nil }
            month = Int(body[2] & 0x78) >> 3
            day = Int(body[2] & 0x07) << 2 | Int(body[3] >> 6)
            hours = Int(body[3] & 0x3E) >> 1
            minutes = Int(body[3] & 0x01) << 5 | Int(body[4] >> 3)
            headerLength = 5
        default:  // month, day, hours, minutes, seconds
            guard body.count >= 6 else { return nil }
            month = Int(body[2] & 0x78) >> 3
            day = Int(body[2] & 0x07) << 2 | Int(body[3] >> 6)
            hours = Int(body[3] & 0x3E) >> 1
            minutes = Int(body[3] & 0x01) << 5 | Int(body[4] >> 3)
            seconds = Int(body[4] & 0x03) << 3 | Int(body[5] >> 5)
            headerLength = 6
        }

        return FISBAPDU(
            productID: productID,
            isSegmented: isSegmented,
            month: month,
            day: day,
            hours: hours,
            minutes: minutes,
            seconds: seconds,
            payload: Array(body.dropFirst(headerLength))
        )
    }

    public func decodeProduct() -> FISBProduct {
        if isSegmented { return .segmented(productID: productID) }
        switch productID {
        case 63:
            guard let product = NEXRADGlobalBlock.decode(payload: payload, scope: .regional) else {
                return .malformed(productID: productID)
            }
            return .nexrad(product)
        case 64:
            guard let product = NEXRADGlobalBlock.decode(payload: payload, scope: .conus) else {
                return .malformed(productID: productID)
            }
            return .nexrad(product)
        case 8, 413:
            // Product 8 (NOTAMs) and 413 (generic text) share the DLAC
            // record encoding; the leading token in each record says which
            // kind it is, so one decoder serves both.
            return .text(FISBTextReport.reports(fromDLACPayload: payload))
        default:
            return .unhandled(productID: productID)
        }
    }
}

/// A decoded FIS-B product. Everything Phase 4 doesn't render is counted,
/// not decoded.
public enum FISBProduct: Sendable {
    case text([FISBTextReport])
    case nexrad(NEXRADProduct)
    /// Product IDs FlightBag doesn't decode (icing, lightning, graphical
    /// NOTAMs, ...).
    case unhandled(productID: Int)
    /// Segmented APDUs are not reassembled (radar and text are broadcast
    /// unsegmented).
    case segmented(productID: Int)
    case malformed(productID: Int)
}
