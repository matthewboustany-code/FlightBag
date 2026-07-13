import Foundation
import FBModels
import FBFlightPlan

/// Live weather data. FAA implementation is `AviationWeatherGovProvider`;
/// international authorities register their own conformer later.
public protocol WeatherProvider: Sendable {
    func metar(for station: ICAOIdentifier) async throws -> Metar?
    func metars(for stations: [ICAOIdentifier]) async throws -> [Metar]
    func taf(for station: ICAOIdentifier) async throws -> Taf?
}

public protocol NotamProvider: Sendable {
    func notams(for location: ICAOIdentifier) async throws -> [Notam]
}

public protocol PlateProvider: Sendable {
    func plates(for airportId: String, cycle: DataCycle) async throws -> [PlateMetadata]
}

/// Identifies who is filing; opaque until real per-user accounts exist.
public struct FilerIdentity: Codable, Sendable, Hashable {
    public var identifier: String

    public init(identifier: String) {
        self.identifier = identifier
    }

    public static let local = FilerIdentity(identifier: "local")
}

public struct FilingReceipt: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable {
        /// Stored locally, not transmitted anywhere.
        case draft
        case filed
        case rejected
        case cancelled
    }

    public var status: Status
    public var providerReference: String?
    public var message: String?
    public var timestamp: Date

    public init(status: Status, providerReference: String? = nil, message: String? = nil, timestamp: Date = Date()) {
        self.status = status
        self.providerReference = providerReference
        self.message = message
        self.timestamp = timestamp
    }
}

/// Flight plan filing. Implementations: `LocalDraftFilingService` (validate +
/// store, ships first), a Leidos LMFS proxy on the backend (when partner
/// credentials arrive), and mocks for tests.
public protocol FilingService: Sendable {
    func validate(_ plan: ICAOFlightPlan) async throws -> [ValidationIssue]
    func file(_ plan: ICAOFlightPlan, as identity: FilerIdentity) async throws -> FilingReceipt
    func cancel(reference: String, as identity: FilerIdentity) async throws -> FilingReceipt
}

/// Validates and records the plan without transmitting it — the filing path
/// that works before any provider integration exists.
public struct LocalDraftFilingService: FilingService {
    public init() {}

    public func validate(_ plan: ICAOFlightPlan) async throws -> [ValidationIssue] {
        FlightPlanValidator.validate(plan)
    }

    public func file(_ plan: ICAOFlightPlan, as identity: FilerIdentity) async throws -> FilingReceipt {
        let errors = FlightPlanValidator.validate(plan).filter { $0.severity == .error }
        guard errors.isEmpty else {
            return FilingReceipt(status: .rejected, message: errors.map(\.message).joined(separator: " "))
        }
        return FilingReceipt(status: .draft, message: "Saved as draft. Not transmitted to ATC.")
    }

    public func cancel(reference: String, as identity: FilerIdentity) async throws -> FilingReceipt {
        FilingReceipt(status: .cancelled)
    }
}
