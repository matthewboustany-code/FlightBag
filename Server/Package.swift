// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "flightbag-server",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.115.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(path: "../Packages/FlightBagCore"),
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "FBModels", package: "FlightBagCore"),
                .product(name: "FBFlightPlan", package: "FlightBagCore"),
                .product(name: "FBProviders", package: "FlightBagCore"),
            ],
            swiftSettings: [
                // Vapor 4 isn't fully Swift-6-mode clean; revisit when moving to Vapor 5.
                .swiftLanguageMode(.v5),
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "AppTests",
            dependencies: [
                .target(name: "App"),
                .product(name: "VaporTesting", package: "vapor"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
