import Foundation

/// Metadata for one FAA d-TPP terminal procedure chart (approach plate,
/// SID/STAR, airport diagram, …). The PDF URL is data, not code, so it can
/// point at FAA aeronav servers now and our CDN later.
public struct PlateMetadata: Codable, Sendable, Hashable, Identifiable {
    /// Stable identifier within a cycle, e.g. "05816IL18L" (d-TPP pdfName stem).
    public var id: String
    public var airportId: String
    /// d-TPP chart code: IAP, DP, STAR, APD, MIN, LAH, HOT, ODP…
    public var chartCode: String
    /// Human name, e.g. "ILS OR LOC RWY 18L".
    public var chartName: String
    /// PDF file name within the cycle, e.g. "05816IL18L.PDF".
    public var pdfName: String
    public var url: URL?
    public var cycle: String

    public init(id: String, airportId: String, chartCode: String, chartName: String, pdfName: String, url: URL? = nil, cycle: String) {
        self.id = id
        self.airportId = airportId
        self.chartCode = chartCode
        self.chartName = chartName
        self.pdfName = pdfName
        self.url = url
        self.cycle = cycle
    }

    /// Buckets for the d-TPP chart codes seen in real metafiles:
    /// IAP, MIN, DP, STR, APD, HOT, ODP, LAH, DAU.
    public enum Category: String, Codable, Sendable, CaseIterable {
        case approach = "IAP"
        case departure = "DP"
        case arrival = "STR"
        case airportDiagram = "APD"
        case minimums = "MIN"
        case other = "OTHER"

        public var displayName: String {
            switch self {
            case .approach: "Approaches"
            case .departure: "Departures"
            case .arrival: "Arrivals"
            case .airportDiagram: "Airport Diagram"
            case .minimums: "Minimums"
            case .other: "Other"
            }
        }
    }

    public var category: Category {
        switch chartCode {
        case "IAP": .approach
        case "DP", "ODP": .departure
        case "STR": .arrival
        case "APD": .airportDiagram
        case "MIN": .minimums
        default: .other
        }
    }
}
