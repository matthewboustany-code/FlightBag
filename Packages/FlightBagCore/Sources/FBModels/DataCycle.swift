import Foundation

/// One 28-day AIRAC data cycle. All downloadable aviation data (airport DB,
/// plates, chart tiles) is versioned by cycle, and the UI surfaces
/// current/expiring/expired freshness from these dates.
public struct DataCycle: Codable, Sendable, Hashable, Comparable, CustomStringConvertible {
    /// Full effective year, e.g. 2026.
    public let year: Int
    /// 1-based ordinal within the year (13 or 14 cycles per year).
    public let ordinal: Int
    /// Cycle effective instant (AIRAC switchover is 09:01 UTC on the effective date).
    public let effectiveDate: Date

    public static let lengthDays = 28
    public static let length: TimeInterval = 28 * 24 * 3600

    /// AIRAC 2401 effective 2024-01-25 09:01 UTC — the epoch all cycle math derives from.
    private static let epoch: Date = {
        var components = DateComponents()
        components.year = 2024
        components.month = 1
        components.day = 25
        components.hour = 9
        components.minute = 1
        components.timeZone = TimeZone(identifier: "UTC")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }()

    private static func effectiveDate(cyclesFromEpoch n: Int) -> Date {
        epoch.addingTimeInterval(Double(n) * length)
    }

    private static func utcYear(of date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.component(.year, from: date)
    }

    private init(cyclesFromEpoch n: Int) {
        let effective = Self.effectiveDate(cyclesFromEpoch: n)
        let year = Self.utcYear(of: effective)
        // Walk back to the first cycle of this effective year to find the ordinal.
        var first = n
        while Self.utcYear(of: Self.effectiveDate(cyclesFromEpoch: first - 1)) == year {
            first -= 1
        }
        self.year = year
        self.ordinal = n - first + 1
        self.effectiveDate = effective
    }

    /// The cycle in effect at the given instant.
    public static func current(at date: Date = Date()) -> DataCycle {
        let n = Int(floor(date.timeIntervalSince(epoch) / length))
        return DataCycle(cyclesFromEpoch: n)
    }

    /// Parse a cycle identifier like "2607". Fails for identifiers that don't
    /// correspond to a real cycle (e.g. ordinal beyond the year's cycle count).
    public init?(id: String) {
        guard id.count == 4, let yy = Int(id.prefix(2)), let ord = Int(id.suffix(2)), ord >= 1 else { return nil }
        let year = 2000 + yy
        // Scan the year's cycles (bounded: <= 14 per year).
        let approxStart = Int(floor((Double(year - 2024) * 365.25 - 30) * 86400 / Self.length))
        var n = approxStart
        while Self.utcYear(of: Self.effectiveDate(cyclesFromEpoch: n)) < year {
            n += 1
        }
        let candidate = DataCycle(cyclesFromEpoch: n + ord - 1)
        guard candidate.year == year, candidate.ordinal == ord else { return nil }
        self = candidate
    }

    /// Identifier in FAA/AIRAC "YYNN" form, e.g. "2607".
    public var id: String {
        String(format: "%02d%02d", year % 100, ordinal)
    }

    public var expirationDate: Date {
        effectiveDate.addingTimeInterval(Self.length)
    }

    public func next() -> DataCycle {
        let n = Int(round(effectiveDate.timeIntervalSince(Self.epoch) / Self.length))
        return DataCycle(cyclesFromEpoch: n + 1)
    }

    public func previous() -> DataCycle {
        let n = Int(round(effectiveDate.timeIntervalSince(Self.epoch) / Self.length))
        return DataCycle(cyclesFromEpoch: n - 1)
    }

    public func contains(_ date: Date) -> Bool {
        date >= effectiveDate && date < expirationDate
    }

    /// Freshness bucket for UI badges.
    public enum Freshness: Sendable {
        case current
        /// Current but within `warningDays` of expiring.
        case expiring
        case expired
        /// Effective date is still in the future (next-cycle data downloaded early).
        case notYetEffective
    }

    public func freshness(at date: Date = Date(), warningDays: Int = 5) -> Freshness {
        if date < effectiveDate { return .notYetEffective }
        if date >= expirationDate { return .expired }
        if expirationDate.timeIntervalSince(date) <= Double(warningDays) * 86400 { return .expiring }
        return .current
    }

    public static func < (lhs: DataCycle, rhs: DataCycle) -> Bool {
        lhs.effectiveDate < rhs.effectiveDate
    }

    public var description: String { id }
}
