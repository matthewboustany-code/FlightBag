import Foundation
import FBModels

/// An ICAO (FPL 2012) flight plan. Field names follow the ICAO item numbers
/// pilots know; string formats are validated by `FlightPlanValidator` with
/// rules shared verbatim between the app and the filing backend.
public struct ICAOFlightPlan: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID

    // Item 7
    public var aircraftIdentification: String
    // Item 8
    public var flightRules: FlightRules
    public var flightType: FlightType
    // Item 9
    public var numberOfAircraft: Int
    public var aircraftType: String
    public var wakeTurbulenceCategory: WakeTurbulenceCategory
    // Item 10
    public var equipment: String
    public var surveillanceEquipment: String
    // Item 13
    public var departure: ICAOIdentifier
    /// Estimated off-block time, UTC.
    public var departureTime: Date
    // Item 15
    public var cruisingSpeed: String
    public var cruisingLevel: String
    public var route: String
    // Item 16
    public var destination: ICAOIdentifier
    /// Total estimated elapsed time as "HHMM".
    public var totalEET: String
    public var alternate1: ICAOIdentifier?
    public var alternate2: ICAOIdentifier?
    // Item 18
    public var otherInformation: String
    // Item 19 (supplementary)
    public var fuelEndurance: String?
    public var personsOnBoard: Int?
    public var pilotInCommand: String?
    public var remarks: String?

    public enum FlightRules: String, Codable, Sendable, CaseIterable {
        case ifr = "I"
        case vfr = "V"
        /// IFR first, then VFR.
        case yankee = "Y"
        /// VFR first, then IFR.
        case zulu = "Z"
    }

    public enum FlightType: String, Codable, Sendable, CaseIterable {
        case scheduled = "S"
        case nonScheduled = "N"
        case generalAviation = "G"
        case military = "M"
        case other = "X"
    }

    public enum WakeTurbulenceCategory: String, Codable, Sendable, CaseIterable {
        case light = "L"
        case medium = "M"
        case heavy = "H"
        case superHeavy = "J"
    }

    public init(
        id: UUID = UUID(),
        aircraftIdentification: String = "",
        flightRules: FlightRules = .ifr,
        flightType: FlightType = .generalAviation,
        numberOfAircraft: Int = 1,
        aircraftType: String = "",
        wakeTurbulenceCategory: WakeTurbulenceCategory = .light,
        equipment: String = "",
        surveillanceEquipment: String = "",
        departure: ICAOIdentifier = ICAOIdentifier(""),
        departureTime: Date = Date(),
        cruisingSpeed: String = "",
        cruisingLevel: String = "",
        route: String = "",
        destination: ICAOIdentifier = ICAOIdentifier(""),
        totalEET: String = "",
        alternate1: ICAOIdentifier? = nil,
        alternate2: ICAOIdentifier? = nil,
        otherInformation: String = "",
        fuelEndurance: String? = nil,
        personsOnBoard: Int? = nil,
        pilotInCommand: String? = nil,
        remarks: String? = nil
    ) {
        self.id = id
        self.aircraftIdentification = aircraftIdentification
        self.flightRules = flightRules
        self.flightType = flightType
        self.numberOfAircraft = numberOfAircraft
        self.aircraftType = aircraftType
        self.wakeTurbulenceCategory = wakeTurbulenceCategory
        self.equipment = equipment
        self.surveillanceEquipment = surveillanceEquipment
        self.departure = departure
        self.departureTime = departureTime
        self.cruisingSpeed = cruisingSpeed
        self.cruisingLevel = cruisingLevel
        self.route = route
        self.destination = destination
        self.totalEET = totalEET
        self.alternate1 = alternate1
        self.alternate2 = alternate2
        self.otherInformation = otherInformation
        self.fuelEndurance = fuelEndurance
        self.personsOnBoard = personsOnBoard
        self.pilotInCommand = pilotInCommand
        self.remarks = remarks
    }
}

/// A recorded IFR clearance in CRAFT order.
public struct Clearance: Codable, Sendable, Hashable {
    public var clearanceLimit: String
    public var route: String
    public var altitude: String
    public var frequency: String
    public var transponder: String
    public var freeText: String
    public var receivedAt: Date

    public init(
        clearanceLimit: String = "",
        route: String = "",
        altitude: String = "",
        frequency: String = "",
        transponder: String = "",
        freeText: String = "",
        receivedAt: Date = Date()
    ) {
        self.clearanceLimit = clearanceLimit
        self.route = route
        self.altitude = altitude
        self.frequency = frequency
        self.transponder = transponder
        self.freeText = freeText
        self.receivedAt = receivedAt
    }
}
