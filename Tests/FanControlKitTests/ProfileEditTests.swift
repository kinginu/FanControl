import Foundation
import Testing
import FanControlCore
@testable import FanControlKit

/// `FanControlManager.profile(changing:fanIndex:to:fans:)`: the profile that
/// `setFanControlMode` / `setFanRPM` apply when the user changes one fan.
struct ProfileEditTests {
    private let fans = [FanDevice(id: 0, name: "Fan 1", minRPM: 2317, maxRPM: 6800),
                        FanDevice(id: 1, name: "Fan 2", minRPM: 2317, maxRPM: 6800)]

    @Test func testPresetDefaultModeKeptForUntouchedFans() {
        // Constant High (every fan 5000 via defaultMode); user sets Fan 1 to 4000.
        let updated = FanControlManager.profile(changing: .constantHigh(), fanIndex: 0,
                                                to: .constant(rpm: 4000), fans: fans)
        #expect(updated.id == FanControlManager.customProfileID)
        #expect(!updated.isBuiltIn)
        #expect(updated.modes[0] == .constant(rpm: 4000))
        // Fan 2 stays at the preset's 5000 RPM, explicitly in `modes` (session decision).
        #expect(updated.modes[1] == .constant(rpm: 5000))
        #expect(updated.mode(for: fans[1]) == .constant(rpm: 5000))
        let plan = FanControlEngine.plan(profile: updated, fans: fans, sensors: [], policy: .default,
                                         isEmergency: false)
        #expect(plan == [0: 4000, 1: 5000])
    }

    @Test func testBoostSensorModeKeptForUntouchedFans() {
        let updated = FanControlManager.profile(changing: .boost(), fanIndex: 1, to: .automatic, fans: fans)
        #expect(updated.modes[0] == FanProfile.Preset.boostMode)
        #expect(updated.modes[1] == .automatic)
        #expect(updated.mode(for: fans[1]) == .automatic)
    }

    @Test func testAutomaticPresetOnlyChangesTheEditedFan() {
        let updated = FanControlManager.profile(changing: .automatic(), fanIndex: 0,
                                                to: .constant(rpm: 3000), fans: fans)
        #expect(updated.modes == [0: .constant(rpm: 3000)])
        #expect(updated.mode(for: fans[1]) == .automatic)
    }

    @Test func testCustomSlotKeepsIdentityAndDefaultMode() {
        let slot = FanProfile.defaultCustom1()
        let updated = FanControlManager.profile(changing: slot, fanIndex: 0, to: .constant(rpm: 3000), fans: fans)
        #expect(updated.id == slot.id)
        #expect(updated.name == slot.name)
        #expect(updated.defaultMode == slot.defaultMode)
        #expect(updated.modes[0] == .constant(rpm: 3000))
        #expect(updated.modes[1] == FanProfile.Preset.boostMode)
    }
}
