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
                // GDL90 reception runs in the foreground; no background mode
                // is requested in this phase. Only a true background
                // transition stops it — a permission alert or Control Center
                // drops the scene to .inactive but must not drop the feed.
                .onChange(of: scenePhase, initial: true) { _, phase in
                    switch phase {
                    case .background:
                        environment.gdl90Receiver.stop()
                    default:
                        if adsbEnabled { environment.gdl90Receiver.start() }
                    }
                }
                .onChange(of: adsbEnabled) { _, enabled in
                    if enabled && scenePhase != .background {
                        environment.gdl90Receiver.start()
                    } else if !enabled {
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
