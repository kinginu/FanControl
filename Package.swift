// swift-tools-version: 6.0
import PackageDescription

// Swift 6 language mode for every target (tests included), which implies complete
// strict concurrency checking. Deployment target macOS 26: `.v26` needs tools 6.2, so
// the string form is used to stay on tools 6.0.
let package = Package(
    name: "FanControl",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "FanControlCore", targets: ["FanControlCore"]),
        .library(name: "FanControlSMC", targets: ["FanControlSMC"]),
        .library(name: "FanControlXPC", targets: ["FanControlXPC"]),
        .library(name: "FanControlKit", targets: ["FanControlKit"]),
        // SwiftUI settings pane, profile / curve editors, temperature chart and the stored
        // Fan Control settings (docs/kit.md "UI layer"). Host-specific glue (DynamicNotch's
        // Nook widgets, Live Activity, visibility hook) lives in the host app's own repository.
        .library(name: "FanControlUI", targets: ["FanControlUI"]),
        .executable(name: "FanControlHelper", targets: ["FanControlHelper"]),
        .executable(name: "fanfi-probe", targets: ["FanControlProbe"]),
    ],
    targets: [
        .target(name: "FanControlCore"),
        .target(name: "FanControlXPC", dependencies: ["FanControlCore"]),
        .target(name: "FanControlSMC", dependencies: ["FanControlCore"]),
        .target(name: "FanControlKit", dependencies: ["FanControlCore", "FanControlSMC", "FanControlXPC"]),
        .target(name: "FanControlUI", dependencies: ["FanControlCore", "FanControlKit"]),
        .executableTarget(name: "FanControlHelper", dependencies: ["FanControlCore", "FanControlSMC", "FanControlXPC"]),
        .executableTarget(name: "FanControlProbe", dependencies: ["FanControlCore", "FanControlSMC"]),
        .testTarget(name: "FanControlCoreTests", dependencies: ["FanControlCore"]),
        .testTarget(name: "FanControlSMCTests", dependencies: ["FanControlSMC", "FanControlCore"]),
        .testTarget(name: "FanControlXPCTests", dependencies: ["FanControlXPC", "FanControlCore"]),
        .testTarget(name: "FanControlKitTests", dependencies: ["FanControlKit", "FanControlCore"]),
        .testTarget(name: "FanControlUITests", dependencies: ["FanControlUI", "FanControlCore"]),
    ],
    swiftLanguageModes: [.v6]
)
