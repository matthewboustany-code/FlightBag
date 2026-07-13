//
//  FlightBagApp.swift
//  FlightBag
//

import SwiftUI
import SwiftData

@main
struct FlightBagApp: App {
    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(environment)
        }
        // Local container now; switches to CloudKit private-database sync
        // later — the schema is already CloudKit-safe.
        .modelContainer(for: [
            Flight.self,
            ClearanceRecord.self,
            FlightDocument.self,
            AircraftProfile.self,
        ])
    }
}
