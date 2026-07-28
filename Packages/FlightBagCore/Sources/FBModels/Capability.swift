import Foundation

/// Features that exist only in some airspace.
///
/// FlightBag's data coverage is deliberately uneven: airports, navaids and
/// weather are worldwide, while charts, plates, coded procedures and the whole
/// US government weather-services stack are not. Rather than let those
/// features quietly return nothing outside the US — an empty panel reads as
/// "no hazards here", which is the dangerous interpretation — every one of
/// them is named here and gated on the jurisdiction being viewed.
public enum Capability: String, Codable, Sendable, CaseIterable, Hashable {
    /// FIS-B weather uplink over 978 MHz UAT.
    case fisb
    /// Temporary flight restrictions from tfr.faa.gov.
    case tfr
    /// FAA winds-aloft (FB) forecast product.
    case windsAloft
    /// Internet NEXRAD mosaic.
    case nexrad
    /// Terminal procedure charts (approach plates, airport diagrams).
    case plates
    /// Coded SID/STAR procedures and airways from CIFP.
    case procedures
    /// Assisted filing handoff to a flight-service portal.
    case assistedFiling
    /// The FAA VFR/MVFR/IFR/LIFR category scheme.
    case flightCategories
    /// NOTAMs from the FAA NOTAM Management Service.
    case notams

    /// Why a capability is unavailable, phrased for a pilot rather than a
    /// developer. Shown in place of the feature instead of hiding it silently,
    /// so the absence is explained rather than ambiguous.
    public var unavailableExplanation: String {
        switch self {
        case .fisb:
            "FIS-B weather uplink is a US ground service (978 MHz UAT). ADS-B traffic still works here."
        case .tfr:
            "Temporary flight restrictions come from the FAA and cover US airspace only. Check NOTAMs."
        case .windsAloft:
            "Winds aloft forecasts come from the FAA and cover US airspace only."
        case .nexrad:
            "NEXRAD radar covers the United States only."
        case .plates:
            "Approach plates are available for US airports only."
        case .procedures:
            "Coded departure and arrival procedures are available for US airports only."
        case .assistedFiling:
            "Assisted filing hands off to 1800wxbrief, which files US flight plans. File through your local AIS."
        case .flightCategories:
            "VFR/MVFR/IFR/LIFR are FAA definitions and don't apply outside US airspace."
        case .notams:
            "NOTAMs come from the FAA and cover US airspace only. Brief through your local AIS."
        }
    }
}

extension RuleSet {
    /// What works under this regulator.
    ///
    /// FAA gets everything; everywhere else gets the worldwide subset. This is
    /// intentionally a whitelist rather than a blacklist — a capability added
    /// later is unavailable abroad until someone deliberately says otherwise.
    public var capabilities: Set<Capability> {
        switch self {
        case .faa:
            Set(Capability.allCases)
        case .tcca, .easa, .icao, .icaoMetric:
            []
        }
    }

    public func supports(_ capability: Capability) -> Bool {
        capabilities.contains(capability)
    }
}

extension Jurisdiction {
    public func supports(_ capability: Capability) -> Bool {
        ruleSet.supports(capability)
    }
}
