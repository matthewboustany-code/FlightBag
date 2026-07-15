import Foundation

/// One record from a FIS-B generic text product (413): a METAR, TAF,
/// PIREP, or winds-aloft report.
public struct FISBTextReport: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case metar = "METAR"
        case speci = "SPECI"
        case taf = "TAF"
        case tafAmendment = "TAF.AMD"
        case pirep = "PIREP"
        case windsAloft = "WINDS"
        case other = ""
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

    static func parse(record: String) -> FISBTextReport {
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
