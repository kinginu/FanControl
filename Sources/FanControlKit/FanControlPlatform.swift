import FanControlCore

/// The one supported platform: Apple Silicon Macs (Intel support dropped
/// 2026-10-20). There is no per-architecture branching any more; this type
/// asserts the hardware (`requireSupported()`, backed by
/// `FanControlCore.FanControlHost`) so that non-arm64 Macs fail clearly with
/// `FanControlError.unsupportedPlatform`, and exposes the (single) defaults.
public enum FanControlPlatform {

    /// `true` on Apple Silicon Macs, also under Rosetta 2 (`FanControlHost.isAppleSilicon`).
    public static var isAppleSilicon: Bool { FanControlHost.isAppleSilicon }

    /// `true` if fan control may run on this host (`isAppleSilicon`).
    public static var isSupported: Bool { FanControlHost.isAppleSilicon }

    /// Short description of an unsupported host (`FanControlHost.unsupportedDetail`).
    public static var unsupportedPlatformDetail: String { FanControlHost.unsupportedDetail }

    /// Throws `FanControlError.unsupportedPlatform` unless `isSupported`.
    /// `FanControlManager` calls it before every SMC open.
    public static func requireSupported() throws {
        try FanControlHost.requireAppleSilicon()
    }

    /// `SafetyPolicy.default`: the policy `FanControlManager` starts with.
    /// Kept as an entry point for the smoke app and host glue.
    public static var defaultSafetyPolicy: SafetyPolicy { .default }

    /// `SensorAggregator.definitions`: the aggregate sensors `FanControlManager`
    /// appends to `sensorReadings`. Referenced by DynamicNotch's host glue
    /// (`FanControlWidgetSettings.swift`).
    public static var sensorAggregateDefinitions: [SensorAggregateDefinition] {
        SensorAggregator.definitions
    }
}
