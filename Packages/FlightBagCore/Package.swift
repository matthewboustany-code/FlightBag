// swift-tools-version:6.1
import PackageDescription

// Shared between the iOS app and the Vapor backend.
// Every target here must build on Linux: no UIKit/SwiftUI/CoreLocation imports.
let package = Package(
    name: "FlightBagCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "FBModels", targets: ["FBModels"]),
        .library(name: "FBFlightPlan", targets: ["FBFlightPlan"]),
        .library(name: "FBProviders", targets: ["FBProviders"]),
        .library(name: "FBGDL90", targets: ["FBGDL90"]),
        .library(name: "FBFISB", targets: ["FBFISB"]),
    ],
    targets: [
        .target(name: "FBModels"),
        .target(name: "FBFlightPlan", dependencies: ["FBModels"]),
        .target(name: "FBProviders", dependencies: ["FBModels", "FBFlightPlan"]),
        .target(name: "FBGDL90"),
        .target(name: "FBFISB"),
        .testTarget(name: "FBModelsTests", dependencies: ["FBModels"]),
        .testTarget(name: "FBFlightPlanTests", dependencies: ["FBFlightPlan"]),
        .testTarget(
            name: "FBProvidersTests",
            dependencies: ["FBProviders"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "FBGDL90Tests", dependencies: ["FBGDL90"]),
        .testTarget(name: "FBFISBTests", dependencies: ["FBFISB"]),
    ]
)
