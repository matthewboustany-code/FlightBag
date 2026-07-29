import Foundation

/// One record from a FIS-B text product: a METAR, TAF, PIREP, winds-aloft
/// report (product 413) or a NOTAM (product 8).
public struct FISBTextReport: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case metar = "METAR"
        case speci = "SPECI"
        case taf = "TAF"
        case tafAmendment = "TAF.AMD"
        case pirep = "PIREP"
        case windsAloft = "WINDS"
        // Product 8. The uplink distinguishes the NOTAM series in the leading
        // token; all four are NOTAMs to a reader, but the series is worth
        // keeping — FDC carries regulatory notices and TFR carries airspace.
        case notamD = "NOTAM-D"
        case notamFDC = "NOTAM-FDC"
        case notamTFR = "NOTAM-TFR"
        case notam = "NOTAM"
        case other = ""

        public var isNotam: Bool {
            switch self {
            case .notamD, .notamFDC, .notamTFR, .notam: true
            default: false
            }
        }
    }

    public let kind: Kind
    /// Station/location identifier: the first token after the kind.
    public let station: String
    /// Record text with the leading kind token removed (matches the raw
    /// form used elsewhere in the app, e.g. "KAUS 151953Z ...").
    public let text: String

    /// Splits a DLAC payload into records (separated by 0x1E) and
    /// classifies each by its leading token.
    public static func reports(fromDLACPayload payload: [UInt8]) -> [FISBTextReport] {
        let decoded = DLAC.decode(payload)
        return decoded
            .split(separator: DLAC.recordSeparator)
            .compactMap { record in
                let trimmed = record.trimmingCharacters(
                    in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{03}"))
                )
                guard !trimmed.isEmpty else { return nil }
                return parse(record: trimmed)
            }
    }

    /// Classifies one already-decoded record. Public so consumers can build
    /// a report from text without going through a DLAC payload.
    public static func parse(record: String) -> FISBTextReport {
        let tokens = record.split(separator: " ", omittingEmptySubsequences: true)
        guard let first = tokens.first else {
            return FISBTextReport(kind: .other, station: "", text: record)
        }
        if let kind = Kind(rawValue: String(first)), kind != .other {
            let body = record.dropFirst(first.count).trimmingCharacters(in: .whitespaces)
            let station = body.split(separator: " ").first.map(String.init) ?? ""
            return FISBTextReport(kind: kind, station: station, text: body)
        }
        return FISBTextReport(kind: .other, station: String(first), text: record)
    }
}
