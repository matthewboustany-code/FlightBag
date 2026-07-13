import Foundation
import FBModels

public struct ValidationIssue: Sendable, Hashable, Identifiable, CustomStringConvertible {
    public enum Severity: Sendable, Hashable {
        case error
        case warning
    }

    /// The flight plan field the issue anchors to, for form highlighting.
    public enum Field: String, Sendable, Hashable, CaseIterable {
        case aircraftIdentification
        case aircraftType
        case equipment
        case surveillanceEquipment
        case departure
        case departureTime
        case cruisingSpeed
        case cruisingLevel
        case route
        case destination
        case totalEET
        case alternate1
        case alternate2
        case fuelEndurance
        case personsOnBoard
    }

    public let field: Field
    public let severity: Severity
    public let message: String

    public var id: String { "\(field.rawValue):\(message)" }
    public var description: String { "\(field.rawValue): \(message)" }

    public init(field: Field, severity: Severity, message: String) {
        self.field = field
        self.severity = severity
        self.message = message
    }
}

/// ICAO FPL field validation. Pure and deterministic: the exact same rules
/// run in the app's form UI and in the backend before anything is transmitted
/// to a filing provider.
public enum FlightPlanValidator {
    public static func validate(_ plan: ICAOFlightPlan) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []

        func error(_ field: ValidationIssue.Field, _ message: String) {
            issues.append(ValidationIssue(field: field, severity: .error, message: message))
        }
        func warning(_ field: ValidationIssue.Field, _ message: String) {
            issues.append(ValidationIssue(field: field, severity: .warning, message: message))
        }

        // Item 7 — aircraft identification: 1–7 alphanumerics, no leading digit issues aside, keep simple.
        if plan.aircraftIdentification.isEmpty {
            error(.aircraftIdentification, "Aircraft identification is required.")
        } else if !matches(plan.aircraftIdentification, "^[A-Z0-9]{1,7}$") {
            error(.aircraftIdentification, "Must be 1–7 letters or digits (e.g. N123AB).")
        }

        // Item 9 — type designator: 2–4 alphanumerics starting with a letter.
        if plan.aircraftType.isEmpty {
            error(.aircraftType, "Aircraft type designator is required (e.g. C172).")
        } else if !matches(plan.aircraftType, "^[A-Z][A-Z0-9]{1,3}$") {
            error(.aircraftType, "Use the ICAO type designator, 2–4 characters (e.g. C172, SR22, B738).")
        }

        // Item 10a — equipment.
        if plan.equipment.isEmpty {
            error(.equipment, "Equipment string is required (e.g. SBG).")
        } else if !matches(plan.equipment, "^[A-Z][A-Z0-9]*$") {
            error(.equipment, "Equipment codes are letters/digits, e.g. SBGR.")
        }

        // Item 10b — surveillance.
        if plan.surveillanceEquipment.isEmpty {
            error(.surveillanceEquipment, "Surveillance equipment is required (e.g. S, C, EB1).")
        } else if !matches(plan.surveillanceEquipment, "^[A-Z][A-Z0-9]*$") {
            error(.surveillanceEquipment, "Surveillance codes are letters/digits, e.g. EB1.")
        }

        // Items 13/16 — aerodromes: 4-letter ICAO or ZZZZ (with DEP//DEST/ in item 18).
        validateAerodrome(plan.departure, field: .departure, error: { error($0, $1) })
        validateAerodrome(plan.destination, field: .destination, error: { error($0, $1) })
        if let alt = plan.alternate1 { validateAerodrome(alt, field: .alternate1, error: { error($0, $1) }) }
        if let alt2 = plan.alternate2 {
            if plan.alternate1 == nil {
                error(.alternate2, "Second alternate requires a first alternate.")
            }
            validateAerodrome(alt2, field: .alternate2, error: { error($0, $1) })
        }
        if plan.flightRules != .vfr && plan.alternate1 == nil {
            warning(.alternate1, "IFR flight plans usually require an alternate unless 1-2-3 conditions are met.")
        }

        // Item 15 — cruising speed: N#### (knots), K#### (km/h), or M### (Mach).
        if !matches(plan.cruisingSpeed, "^(N[0-9]{4}|K[0-9]{4}|M[0-9]{3})$") {
            error(.cruisingSpeed, "Speed must be N#### knots, K#### km/h, or M### Mach (e.g. N0140).")
        }

        // Item 15 — level: F### (flight level), A### (altitude in hundreds ft), S/M metric, or VFR.
        if !matches(plan.cruisingLevel, "^(F[0-9]{3}|A[0-9]{3}|S[0-9]{4}|M[0-9]{4}|VFR)$") {
            error(.cruisingLevel, "Level must be A### (altitude, e.g. A090), F### (flight level), or VFR.")
        }

        // Item 15 — route.
        let routeTokens = plan.route.uppercased().split(separator: " ")
        if routeTokens.isEmpty {
            error(.route, "Route is required. Use DCT for direct.")
        } else if let bad = routeTokens.first(where: { !matches(String($0), "^[A-Z0-9./]{1,15}$") }) {
            error(.route, "Route element \"\(bad)\" contains invalid characters.")
        }

        // Item 16 — total EET as HHMM.
        if !matches(plan.totalEET, "^([0-9]{2})([0-5][0-9])$") {
            error(.totalEET, "Total EET must be HHMM (e.g. 0130).")
        } else if plan.totalEET == "0000" {
            error(.totalEET, "Total EET cannot be zero.")
        }

        // Item 19 — endurance as HHMM, must exceed EET.
        if let endurance = plan.fuelEndurance {
            if !matches(endurance, "^([0-9]{2})([0-5][0-9])$") {
                error(.fuelEndurance, "Endurance must be HHMM (e.g. 0430).")
            } else if let eet = minutes(plan.totalEET), let end = minutes(endurance), end <= eet {
                warning(.fuelEndurance, "Fuel endurance should exceed the total EET.")
            }
        }

        if let pob = plan.personsOnBoard, pob < 1 {
            error(.personsOnBoard, "Persons on board must be at least 1.")
        }

        if plan.departureTime < Date(timeIntervalSinceNow: -30 * 60) {
            warning(.departureTime, "Departure time is in the past.")
        }

        return issues
    }

    private static func validateAerodrome(
        _ identifier: ICAOIdentifier,
        field: ValidationIssue.Field,
        error: (ValidationIssue.Field, String) -> Void
    ) {
        if identifier.rawValue.isEmpty {
            error(field, "Aerodrome is required.")
        } else if !matches(identifier.rawValue, "^[A-Z]{4}$") {
            error(field, "Use the 4-letter ICAO identifier (e.g. KAUS), or ZZZZ with details in Other Information.")
        }
    }

    private static func minutes(_ hhmm: String) -> Int? {
        guard hhmm.count == 4, let h = Int(hhmm.prefix(2)), let m = Int(hhmm.suffix(2)) else { return nil }
        return h * 60 + m
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}
