// swift-tools-version: 5.9
// Scratch package that type-checks FanControl/DynamicNotchIntegration/*.swift against the
// real macOS SDK + sindresorhus/Defaults + sindresorhus/Settings. Not part of FanControl/Package.swift.
import PackageDescription
import Foundation

// `TYPECHECK_SWIFT6=1 swift build` compiles the integration target in the Swift 6 language
// mode (complete strict concurrency) without changing the dependencies' modes.
let swift6: [SwiftSetting] = ProcessInfo.processInfo.environment["TYPECHECK_SWIFT6"] == "1"
    ? [.unsafeFlags(["-swift-version", "6"])]
    : []

let package = Package(
    name: "IntegrationTypeCheck",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "FanControl", path: "../.."),
        .package(url: "https://github.com/sindresorhus/Defaults", from: "8.2.0"),
        .package(url: "https://github.com/sindresorhus/Settings", from: "3.0.0"),
    ],
    targets: [
        .target(
            name: "IntegrationTypeCheck",
            dependencies: [
                .product(name: "FanControlCore", package: "FanControl"),
                .product(name: "FanControlKit", package: "FanControl"),
                .product(name: "Defaults", package: "Defaults"),
                .product(name: "Settings", package: "Settings"),
            ],
            swiftSettings: swift6
        ),
    ]
)
