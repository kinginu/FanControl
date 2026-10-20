import Foundation
import Testing
import FanControlCore
@testable import FanControlKit

@Suite("Platform", .tags(.manager, .safety))
struct FanControlPlatformTests {
    @Test func detectsHostArchitecture() throws {
        #if arch(arm64)
        #expect(FanControlPlatform.isAppleSilicon)
        #expect(FanControlPlatform.isSupported)
        try FanControlPlatform.requireSupported()
        #endif
        #expect(FanControlPlatform.isSupported == FanControlHost.isAppleSilicon)
        if !FanControlPlatform.isSupported {
            #expect(throws: FanControlError.unsupportedPlatform(FanControlHost.unsupportedDetail)) {
                try FanControlPlatform.requireSupported()
            }
        }
    }

    /// No per-architecture defaults any more (Intel dropped 2026-10-20).
    @Test func singleDefaults() {
        #expect(FanControlPlatform.defaultSafetyPolicy == .default)
        #expect(!FanControlPlatform.defaultSafetyPolicy.emergencySensorPrefixes.contains("TG"))
        #expect(FanControlPlatform.sensorAggregateDefinitions == SensorAggregator.definitions)
        #expect(FanControlError.unsupportedPlatform("x").errorDescription?.contains("Apple silicon") == true)
    }

    #if os(macOS)
    @Test @MainActor func managerStartsWithPlatformPolicy() {
        let defaults = ScratchDefaults()
        let manager = Isolated.manager(defaults: defaults)
        #expect(manager.safetyPolicy == FanControlPlatform.defaultSafetyPolicy)
        #expect(manager.substitutedSensorKeys.isEmpty)
    }
    #endif
}
