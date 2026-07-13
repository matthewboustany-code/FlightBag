import Foundation

/// RFC-4180 CSV parsing for NASR subscriber files: quoted fields, embedded
/// commas/quotes/newlines, header row with named-column access.
struct CSVTable {
    let headers: [String]
    let rows: [[String]]
    private let columnIndex: [String: Int]

    init(data: Data) throws {
        var records: [[String]] = []
        var field = ""
        var record: [String] = []
        var inQuotes = false
        var previousWasQuote = false

        let text = String(decoding: data, as: UTF8.self)
        var iterator = text.makeIterator()
        while let char = iterator.next() {
            if inQuotes {
                if char == "\"" {
                    if previousWasQuote {
                        field.append("\"")
                        previousWasQuote = false
                    } else {
                        previousWasQuote = true
                    }
                } else if previousWasQuote {
                    // Quote closed the field; current char is a delimiter.
                    // Note: in a Swift String, CRLF is one Character, so
                    // newline checks must use `isNewline`, never == "\n".
                    previousWasQuote = false
                    inQuotes = false
                    if char == "," {
                        record.append(field); field = ""
                    } else if char.isNewline {
                        record.append(field); field = ""
                        records.append(record); record = []
                    } else {
                        field.append(char)
                    }
                } else {
                    field.append(char)
                }
            } else {
                if char == "\"" && field.isEmpty {
                    inQuotes = true
                } else if char == "," {
                    record.append(field); field = ""
                } else if char.isNewline {
                    if !field.isEmpty || !record.isEmpty {
                        record.append(field); field = ""
                        records.append(record); record = []
                    }
                } else {
                    field.append(char)
                }
            }
        }
        if previousWasQuote { inQuotes = false }
        if !field.isEmpty || !record.isEmpty {
            record.append(field)
            records.append(record)
        }

        guard let headerRow = records.first else {
            throw IngestError("CSV file is empty")
        }
        headers = headerRow
        rows = Array(records.dropFirst())
        columnIndex = Dictionary(uniqueKeysWithValues: headerRow.enumerated().map { ($1, $0) })
    }

    /// Access a field by column name; empty string and missing map to nil.
    func value(_ row: [String], _ column: String) -> String? {
        guard let index = columnIndex[column], index < row.count else { return nil }
        let value = row[index].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    func double(_ row: [String], _ column: String) -> Double? {
        value(row, column).flatMap(Double.init)
    }

    func int(_ row: [String], _ column: String) -> Int? {
        value(row, column).flatMap { Int($0) ?? Double($0).map(Int.init) }
    }
}

struct IngestError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Parse "118.15" (MHz) into kHz without floating-point drift.
func megahertzStringToKHz(_ string: String) -> Int? {
    let parts = string.split(separator: ".", maxSplits: 1)
    guard let whole = Int(parts[0]), whole > 0 else { return nil }
    var khz = whole * 1000
    if parts.count == 2 {
        let fraction = parts[1].prefix(3)
        let padded = fraction.padding(toLength: 3, withPad: "0", startingAt: 0)
        guard let frac = Int(padded) else { return nil }
        khz += frac
    }
    return khz
}
