// swift-tools-version: 5.9
// Scratch package that type-checks the remaining FanControl/DynamicNotchIntegration/*.swift
// drop-ins (host-specific glue) and the PATCHES.md snippets against the real macOS SDK and the
// FanControlUI library. Not part of FanControl/Package.swift.
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
                .product(name: "FanControlUI", package: "FanControl"),
            ],
            swiftSettings: swift6
        ),
        // The host's store and FanControlUI's store see each other's writes (same keys, KVO).
        .testTarget(
            name: "HostStoreInteropTests",
            dependencies: [
                "IntegrationTypeCheck",
                .product(name: "FanControlUI", package: "FanControl"),
            ],
            swiftSettings: swift6
        ),
    ]
)
