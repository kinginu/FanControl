// swift-tools-version: 5.9
// Scratch package that type-checks FanControl/DynamicNotchIntegration/*.swift against the
// real macOS SDK (settings storage: FanControlSettingsStorage.swift, first-party since
// 2026-10-20 — sindresorhus/Defaults was removed). Not part of FanControl/Package.swift.
import PackageDescription
import Foundation

// `TYPECHECK_SWIFT6=1 swift build` compiles the integration target in the Swift 6 language
// mode (complete strict concurrency) without changing the dependencies' modes.
let swift6: [SwiftSetting] = ProcessInfo.processInfo.environment["TYPECHECK_SWIFT6"] == "1"
    ? [.unsafeFlags(["-swift-version", "6"])]
    : []

let package = Package(
    name: "IntegrationTypeCheck",
    platforms: [.macOS("26.0")],   // follows FanControl/Package.swift
    dependencies: [
        .package(name: "FanControl", path: "../.."),
    ],
    targets: [
        .target(
            name: "IntegrationTypeCheck",
            dependencies: [
                .product(name: "FanControlCore", package: "FanControl"),
                .product(name: "FanControlKit", package: "FanControl"),
            ],
            swiftSettings: swift6
        ),
        // Stored-format compatibility of the Fan Control settings keys (SettingsStore vs the JSON
        // strings sindresorhus/Defaults wrote). Fixture shared with DynamicNotchApp/Tests.
        .testTarget(
            name: "FanControlSettingsCompatTests",
            dependencies: ["IntegrationTypeCheck"],
            swiftSettings: swift6
        ),
    ]
)
