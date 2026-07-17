//
//  FlightBagApp.swift
//  FlightBag
//

import SwiftUI
import SwiftData

/// Exists only to catch the background-URLSession relaunch: when downloads
/// finish while the app is dead, iOS relaunches it and hands over a
/// completion handler that DownloadService calls once the session's events
/// drain.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        MainActor.assumeIsolated {
            DownloadService.backgroundCompletionHandler = completionHandler
        }
    }
}

@main
struct FlightBagApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
