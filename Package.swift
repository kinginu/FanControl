// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FanControl",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FanControlCore", targets: ["FanControlCore"]),
        .library(name: "FanControlSMC", targets: ["FanControlSMC"]),
        .library(name: "FanControlXPC", targets: ["FanControlXPC"]),
        .library(name: "FanControlKit", targets: ["FanControlKit"]),
        .executable(name: "FanControlHelper", targets: ["FanControlHelper"]),
    ],
    targets: [
        .target(name: "FanControlCore"),
        .target(name: "FanControlXPC"),
        .target(name: "FanControlSMC", dependencies: ["FanControlCore"]),
        .target(name: "FanControlKit", dependencies: ["FanControlCore", "FanControlSMC", "FanControlXPC"]),
        .executableTarget(name: "FanControlHelper", dependencies: ["FanControlCore", "FanControlSMC", "FanControlXPC"]),
        .testTarget(name: "FanControlCoreTests", dependencies: ["FanControlCore"]),
        .testTarget(name: "FanControlSMCTests", dependencies: ["FanControlSMC", "FanControlCore"]),
        .testTarget(name: "FanControlXPCTests", dependencies: ["FanControlXPC"]),
        .testTarget(name: "FanControlKitTests", dependencies: ["FanControlKit", "FanControlCore"]),
    ]
)
