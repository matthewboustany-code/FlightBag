import Foundation
import SwiftData

// User-created data, persisted with SwiftData. The schema follows CloudKit's
// rules from day one (every attribute defaulted, every relationship optional,
// no unique constraints) so private-database sync can be switched on later
// without a migration.

@Model
final class Flight {
    var createdAt: Date = Date()
    var departure: String = ""
    var destination: String = ""
    var routeString: String = ""
    /// Serialized ICAOFlightPlan (FBFlightPlan) as JSON; keeping it a blob
    /// avoids mirroring every FPL field into the schema.
    var flightPlanData: Data?
    var notes: String = ""

    @Relationship(deleteRule: .cascade, inverse: \ClearanceRecord.flight)
    var clearances: [ClearanceRecord]? = []

    @Relationship(deleteRule: .cascade, inverse: \FlightDocument.flight)
    var documents: [FlightDocument]? = []

    var aircraft: AircraftProfile?

    init(departure: String = "", destination: String = "", routeString: String = "") {
        self.departure = departure
        self.destination = destination
        self.routeString = routeString
    }
}

/// A recorded IFR clearance in CRAFT order.
@Model
final class ClearanceRecord {
    var receivedAt: Date = Date()
    var clearanceLimit: String = ""
    var route: String = ""
    var altitude: String = ""
    var frequency: String = ""
    var transponder: String = ""
    var freeText: String = ""

    var flight: Flight?

    init() {}
}

@Model
final class FlightDocument {
    var createdAt: Date = Date()
    var title: String = ""
    /// UTType identifier, e.g. "com.adobe.pdf", "public.jpeg".
    var contentType: String = ""
    @Attribute(.externalStorage) var data: Data?

    var flight: Flight?

    init(title: String = "", contentType: String = "") {
        self.title = title
        self.contentType = contentType
    }
}

@Model
final class AircraftProfile {
    var tailNumber: String = ""
    /// ICAO type designator, e.g. "C172".
    var typeDesignator: String = ""
    var equipment: String = ""
    var surveillanceEquipment: String = ""
    var wakeCategory: String = "L"
    var cruiseTrueAirspeedKt: Int = 0
    var fuelBurnGph: Double = 0
    var homeBase: String = ""

    init(tailNumber: String = "") {
        self.tailNumber = tailNumber
    }
}
