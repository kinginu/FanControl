import Foundation
import Testing
import FanControlCore
@testable import FanControlKit

struct FanControlPlatformTests {
    @Test func testDetectsHostArchitecture() throws {
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
    @Test func testSingleDefaults() {
        #expect(FanControlPlatform.defaultSafetyPolicy == .default)
        #expect(!FanControlPlatform.defaultSafetyPolicy.emergencySensorPrefixes.contains("TG"))
        #expect(FanControlPlatform.sensorAggregateDefinitions == SensorAggregator.definitions)
        #expect(FanControlError.unsupportedPlatform("x").errorDescription?.contains("Apple silicon") == true)
    }

    #if os(macOS)
    @Test @MainActor func testManagerStartsWithPlatformPolicy() {
        let manager = FanControlManager(defaults: UserDefaults(suiteName: "FanControlPlatformTests")!)
        #expect(manager.safetyPolicy == FanControlPlatform.defaultSafetyPolicy)
        #expect(manager.substitutedSensorKeys.isEmpty)
    }
    #endif
}
