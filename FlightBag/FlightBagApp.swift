//
//  FlightBagApp.swift
//  FlightBag
//

import SwiftUI
import SwiftData

@main
struct FlightBagApp: App {
    @State private var environment = AppEnvironment()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("adsbEnabled") private var adsbEnabled = true

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(environment)
                // GDL90 reception runs only while active; no background
                // mode is requested in this phase.
                .onChange(of: scenePhase, initial: true) { _, phase in
                    if phase == .active && adsbEnabled {
                        environment.gdl90Receiver.start()
                    } else {
                        environment.gdl90Receiver.stop()
                    }
                }
                .onChange(of: adsbEnabled) { _, enabled in
                    if enabled && scenePhase == .active {
                        environment.gdl90Receiver.start()
                    } else {
                        environment.gdl90Receiver.stop()
                    }
                }
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
