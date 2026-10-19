import Foundation
import Testing
import FanControlCore
@testable import FanControlKit

struct FanControlPlatformTests {
    @Test func testDetectsHostArchitecture() {
        #if arch(arm64)
        #expect(FanControlPlatform.isAppleSilicon)
        #endif
        #expect(FanControlPlatform.defaultSafetyPolicy
                == .default(appleSilicon: FanControlPlatform.isAppleSilicon))
        #expect(FanControlPlatform.defaultSafetyPolicy.emergencySensorPrefixes.contains("TG")
                == !FanControlPlatform.isAppleSilicon)
    }

    #if os(macOS)
    @Test @MainActor func testManagerStartsWithPlatformPolicy() {
        let manager = FanControlManager(defaults: UserDefaults(suiteName: "FanControlPlatformTests")!)
        #expect(manager.safetyPolicy == FanControlPlatform.defaultSafetyPolicy)
        #expect(manager.substitutedSensorKeys.isEmpty)
    }
    #endif
}
