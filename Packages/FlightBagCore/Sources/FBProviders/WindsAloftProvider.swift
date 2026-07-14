import Foundation
import FBModels

/// One station's winds-aloft forecast from the NWS FB product.
public struct WindsAloftStation: Sendable, Hashable {
    public struct Entry: Sendable, Hashable {
        /// nil direction means light and variable ("9900").
        public var fromDegrees: Double?
        public var speedKt: Double
        public var temperatureC: Int?

        public init(fromDegrees: Double?, speedKt: Double, temperatureC: Int? = nil) {
            self.fromDegrees = fromDegrees
            self.speedKt = speedKt
            self.temperatureC = temperatureC
        }
    }

    /// 3-letter NWS station identifier (usually a VOR, e.g. "AUS").
    public var identifier: String
    /// Forecast entries keyed by altitude in feet MSL (3000, 6000, …).
    public var entries: [Int: Entry]

    public init(identifier: String, entries: [Int: Entry]) {
        self.identifier = identifier
        self.entries = entries
    }

    /// The forecast at the FB level nearest the requested altitude,
    /// preferring the lower level on ties.
    public func entryNearest(altitudeFt: Int) -> Entry? {
        entries.min {
            (abs($0.key - altitudeFt), $0.key) < (abs($1.key - altitudeFt), $1.key)
        }?.value
    }
}

public protocol WindsAloftProvider: Sendable {
    /// Winds-aloft stations for the contiguous US at the given forecast
    /// period (6, 12, or 24 hours).
    func windsAloft(forecastHours: Int) async throws -> [WindsAloftStation]
}

extension AviationWeatherGovProvider: WindsAloftProvider {
    /// The Data API serves the FB text per lookout region; low-level covers
    /// 3000–39000 ft which is all a GA navlog needs.
    private static let conusRegions = ["bos", "mia", "chi", "dfw", "slc", "sfo"]

    public func windsAloft(forecastHours: Int = 6) async throws -> [WindsAloftStation] {
        var stations: [String: WindsAloftStation] = [:]
        for region in Self.conusRegions {
            var components = URLComponents(url: windtempURL, resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "region", value: region),
                URLQueryItem(name: "level", value: "low"),
                URLQueryItem(name: "fcst", value: String(forecastHours)),
            ]
            let data = try await http.get(components.url!)
            guard let text = String(data: data, encoding: .utf8) else { continue }
            for station in FBWindsParser.parse(text) {
                stations[station.identifier] = station
            }
        }
        return Array(stations.values)
    }
}

/// Parser for the NWS FB (winds and temperatures aloft) text product:
///
///     FT  3000    6000    9000   12000   18000   24000  30000  34000  39000
///     ABI      9900+17 3208+12 3111+07 3506-06 2913-16 341730 011739 032349
///
/// Group format is ddff(±tt): dd = direction/10, ff = knots. "9900" is light
/// and variable; dd 51–86 encodes direction−50 with speed+100; above 24000 ft
/// the sign is omitted and temperatures are negative.
public enum FBWindsParser {
    public static func parse(_ text: String) -> [WindsAloftStation] {
        var altitudeColumns: [(altitude: Int, range: Range<Int>)] = []
        var stations: [WindsAloftStation] = []

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(line)
            if line.hasPrefix("FT ") {
                altitudeColumns = headerColumns(line)
                continue
            }
            guard !altitudeColumns.isEmpty else { continue }
            // Station rows: 3-letter identifier at the start of the line.
            guard line.count > 4, line.prefix(3).allSatisfy({ $0.isUppercase && $0.isLetter }),
                  line.dropFirst(3).first == " " else { continue }

            let identifier = String(line.prefix(3))
            var entries: [Int: WindsAloftStation.Entry] = [:]
            let characters = Array(line)
            for (altitude, range) in altitudeColumns {
                // Never let a column window reach into the station identifier.
                let lower = max(range.lowerBound, 4)
                guard lower < characters.count else { break }
                let slice = characters[lower..<min(range.upperBound, characters.count)]
                // The window can clip a neighboring group; the entry for this
                // column is the last whitespace-separated token in it.
                let group = String(slice).split(separator: " ").last.map(String.init) ?? ""
                if let entry = parseGroup(group) {
                    entries[altitude] = entry
                }
            }
            if !entries.isEmpty {
                stations.append(WindsAloftStation(identifier: identifier, entries: entries))
            }
        }
        return stations
    }

    /// Column ranges from the "FT  3000    6000 …" header. Each data group is
    /// right-aligned under its altitude label, extending left up to 7 chars.
    private static func headerColumns(_ header: String) -> [(Int, Range<Int>)] {
        var columns: [(Int, Range<Int>)] = []
        var index = header.startIndex
        while index < header.endIndex {
            if header[index].isNumber {
                let start = index
                while index < header.endIndex, header[index].isNumber {
                    index = header.index(after: index)
                }
                if let altitude = Int(header[start..<index]) {
                    let end = header.distance(from: header.startIndex, to: index)
                    columns.append((altitude, max(0, end - 7)..<(end + 1)))
                }
            } else {
                index = header.index(after: index)
            }
        }
        return columns
    }

    static func parseGroup(_ group: String) -> WindsAloftStation.Entry? {
        guard group.count >= 4 else { return nil }
        let wind = String(group.prefix(4))
        guard let dd = Int(wind.prefix(2)), let ff = Int(wind.suffix(2)) else { return nil }

        var temperature: Int?
        let tempPart = String(group.dropFirst(4))
        if !tempPart.isEmpty {
            if tempPart.hasPrefix("+") || tempPart.hasPrefix("-") {
                temperature = Int(tempPart)
            } else {
                // Above 24 000 ft the sign is dropped and temps are negative.
                temperature = Int(tempPart).map { -$0 }
            }
        }

        if dd == 99 && ff == 0 {
            return WindsAloftStation.Entry(fromDegrees: nil, speedKt: 0, temperatureC: temperature)
        }
        if dd > 50 && dd <= 86 {
            return WindsAloftStation.Entry(fromDegrees: Double((dd - 50) * 10), speedKt: Double(ff + 100), temperatureC: temperature)
        }
        guard dd <= 36 else { return nil }
        return WindsAloftStation.Entry(fromDegrees: Double(dd == 36 ? 360 : dd * 10), speedKt: Double(ff), temperatureC: temperature)
    }
}
