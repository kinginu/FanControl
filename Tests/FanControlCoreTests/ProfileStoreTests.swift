import Foundation
import Testing
@testable import FanControlCore

/// The fixed set of six profiles (`ProfileStore`, docs/kit.md "Profiles").
struct ProfileStoreTests {
    typealias ID = FanProfile.BuiltInID

    let fans = [FanDevice(id: 0, name: "Fan 1", minRPM: 2317, maxRPM: 6800),
                FanDevice(id: 1, name: "Fan 2", minRPM: 2317, maxRPM: 6800)]

    @Test func testFixedSetAndOrder() {
        let store = ProfileStore()
        #expect(store.profiles.map(\.id) == FanProfile.fixedProfileIDs)
        #expect(store.profiles.map(\.id) == [ID.automatic, ID.constantQuiet, ID.constantHigh, ID.boost,
                                             ID.custom1, ID.custom2])
        #expect(store.profiles.map(\.name) == ["Automatic", "Constant Quiet", "Constant High", "Boost",
                                               "Custom 1", "Custom 2"])
        #expect(store.profiles.map(\.isBuiltIn) == [true, true, true, true, false, false])
        #expect(store.profiles.map(\.isCustomSlot) == [false, false, false, false, true, true])
        #expect(Set(FanProfile.fixedProfileIDs).count == 6)
        #expect(!FanProfile.fixedProfileIDs.contains(ID.silent))
        #expect(!FanProfile.fixedProfileIDs.contains(ID.maximum))
        #expect(store.activeProfileID == nil)
    }

    @Test func testPresetDefaults() {
        for fan in fans {
            #expect(FanProfile.automatic().mode(for: fan) == .automatic)
            #expect(FanProfile.constantQuiet().mode(for: fan) == .constant(rpm: 3000))
            #expect(FanProfile.constantHigh().mode(for: fan) == .constant(rpm: 5000))
            #expect(FanProfile.boost().mode(for: fan)
                    == .sensor(sensorKey: "agg:cpu", startTemperature: 70, maxTemperature: 95))
            #expect(FanProfile.defaultCustom1().mode(for: fan) == FanProfile.boost().mode(for: fan))
            #expect(FanProfile.defaultCustom2().mode(for: fan) == .constant(rpm: 3500))
        }
        #expect(FanProfile.fixedDefault(id: UUID()) == nil)
        #expect(FanProfile.fixedDefault(id: ID.boost) == .boost())
    }

    @Test func testModeFallbackAndResolved() {
        var profile = FanProfile.boost()
        profile.modes[1] = .automatic
        #expect(profile.mode(for: fans[0]) == FanProfile.Preset.boostMode)
        #expect(profile.mode(for: fans[1]) == .automatic)

        let resolved = profile.resolved(for: fans)
        #expect(resolved.modes == [0: FanProfile.Preset.boostMode, 1: .automatic])
        #expect(resolved.defaultMode == profile.defaultMode)
        #expect(resolved.modes.values.contains { $0.isManual })
        // Automatic stays without manual entries (no write session needed).
        #expect(!FanProfile.automatic().resolved(for: fans).modes.values.contains { $0.isManual })
    }

    @Test func testPresetsAreReadOnly() {
        var store = ProfileStore()
        var quiet = FanProfile.constantQuiet()
        quiet.defaultMode = .constant(rpm: 1000)
        #expect(store.upsert(quiet) == false)
        #expect(store.profile(id: ID.constantQuiet) == .constantQuiet())
        #expect(store.rename(id: ID.boost, to: "Turbo") == false)
        #expect(store.reset(id: ID.boost) == false)
        // Legacy built-ins are never stored.
        #expect(store.upsert(.silent(for: fans)) == false)
        #expect(store.upsert(.maximum(for: fans)) == false)
        #expect(store.profiles.count == 6)
        // Direct assignment is normalized as well.
        store.profiles.removeAll { $0.id == ID.custom2 }
        store.profiles[2] = FanProfile(id: ID.constantHigh, name: "Hacked", defaultMode: .constant(rpm: 1))
        store.profiles.insert(.silent(for: fans), at: 0)
        #expect(store.profiles == ProfileStore().profiles)
    }

    @Test func testEditRenameReset() {
        var store = ProfileStore()
        var custom = store.profile(id: ID.custom2)!
        custom.modes = [0: .sensor(sensorKey: "agg:gpu", startTemperature: 45, maxTemperature: 75),
                        1: .constant(rpm: 4000)]
        #expect(store.upsert(custom) == true)
        #expect(store.profile(id: ID.custom2)?.mode(for: fans[0])
                == .sensor(sensorKey: "agg:gpu", startTemperature: 45, maxTemperature: 75))
        #expect(store.isModified(id: ID.custom2, fans: fans))

        #expect(store.rename(id: ID.custom2, to: "Night") == true)
        #expect(store.profile(id: ID.custom2)?.name == "Night")
        #expect(store.profile(id: ID.custom2)?.modes == custom.modes)
        #expect(store.rename(id: ID.custom2, to: "   ") == true)
        #expect(store.profile(id: ID.custom2)?.name == "Custom 2")

        // A materialized-but-unchanged slot is not "modified".
        #expect(store.upsert(FanProfile.defaultCustom1().resolved(for: fans)) == true)
        #expect(!store.isModified(id: ID.custom1, fans: fans))
        #expect(store.isModified(id: ID.custom1))

        store.activeProfileID = ID.custom2
        #expect(store.reset(id: ID.custom2) == true)
        #expect(store.profile(id: ID.custom2) == .defaultCustom2())
        #expect(store.activeProfileID == ID.custom2)
        #expect(store.activeProfile == .defaultCustom2())

        // isBuiltIn cannot be smuggled into a slot.
        var sneaky = FanProfile.defaultCustom1()
        sneaky.isBuiltIn = true
        #expect(store.upsert(sneaky) == true)
        #expect(store.profile(id: ID.custom1)?.isBuiltIn == false)
    }

    @Test func testDeleteIsNoOpAndActiveNormalized() {
        var store = ProfileStore()
        for id in FanProfile.fixedProfileIDs { #expect(store.delete(id: id) == false) }
        #expect(store.profiles.count == 6)
        store.activeProfileID = ID.boost
        #expect(store.activeProfile == .boost())
        // Ids outside the six (legacy built-ins, the manager's "Custom") resolve to nil = Automatic.
        store.activeProfileID = ID.silent
        #expect(store.activeProfileID == nil)
        store.activeProfileID = UUID(uuidString: "6F1A0000-0000-4000-8000-0000000000C0")!
        #expect(store.activeProfileID == nil)
        #expect(ProfileStore(activeProfileID: ID.maximum).activeProfileID == nil)
    }

    /// Programmatic profiles stored by FanControlManager (setFanRPM's "Custom",
    /// HelperSmokeApp) are kept after the six, not shown as fixed profiles.
    @Test func testAdditionalProfiles() throws {
        var store = ProfileStore()
        let managerCustom = FanProfile(id: UUID(uuidString: "6F1A0000-0000-4000-8000-0000000000C0")!,
                                       name: "Custom", modes: [0: .constant(rpm: 3000)])
        #expect(store.upsert(managerCustom) == true)
        store.activeProfileID = managerCustom.id
        #expect(store.activeProfile == managerCustom)
        #expect(store.fixedProfiles.map(\.id) == FanFile.ids)
        #expect(store.additionalProfiles == [managerCustom])
        // Placed first by hand → still after the six.
        store.profiles = [managerCustom] + store.fixedProfiles + [managerCustom]
        #expect(store.profiles.map(\.id) == FanFile.ids + [managerCustom.id])

        var updated = managerCustom
        updated.modes[0] = .constant(rpm: 3200)
        #expect(store.upsert(updated) == true)
        #expect(store.additionalProfiles == [updated])

        let data = try ProfileStore.encodeJSON(store)
        #expect(try ProfileStore.decodeJSON(data) == store)

        #expect(store.delete(id: managerCustom.id) == true)
        #expect(store.additionalProfiles.isEmpty)
        #expect(store.activeProfileID == nil)
        #expect(store.delete(id: managerCustom.id) == false)
    }

    @Test func testCodableRoundTrip() throws {
        var store = ProfileStore()
        store.rename(id: ID.custom1, to: "Gaming")
        var custom2 = store.profile(id: ID.custom2)!
        custom2.modes = [1: .constant(rpm: 2600)]
        store.upsert(custom2)
        store.activeProfileID = ID.custom1

        let data = try ProfileStore.encodeJSON(store)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"schemaVersion\" : 2"))
        let decoded = try ProfileStore.decodeJSON(data)
        #expect(decoded == store)
        #expect(decoded.profile(id: ID.custom1)?.name == "Gaming")
        #expect(decoded.profile(id: ID.custom2)?.mode(for: fans[1]) == .constant(rpm: 2600))
        #expect(decoded.profile(id: ID.custom2)?.mode(for: fans[0]) == .constant(rpm: 3500))
    }

    @Test func testStoredPresetIsRegeneratedFromCode() throws {
        // A v2 store whose preset values differ (e.g. written by an older build) gets today's presets.
        let stale = ProfileStore()
        var json = String(data: try ProfileStore.encodeJSON(stale), encoding: .utf8)!
        json = json.replacingOccurrences(of: "\"rpm\" : 3000", with: "\"rpm\" : 1234")
        #expect(json.contains("1234"))
        let decoded = try ProfileStore.decodeJSON(Data(json.utf8))
        #expect(decoded.profile(id: ID.constantQuiet) == .constantQuiet())
    }

    @Test func testLegacyMigrationFoldsSensorProfile() throws {
        let sensorModes: [Int: FanControlMode] = [0: .sensor(sensorKey: "agg:cpu", startTemperature: 45, maxTemperature: 75),
                                                  1: .constant(rpm: 3000)]
        let smoke = FanProfile(id: UUID(uuidString: "6F1A0000-0000-4000-8000-00000000D0D0")!,
                               name: "Smoke sensor-linked", modes: sensorModes)
        let custom = FanProfile(id: UUID(uuidString: "6F1A0000-0000-4000-8000-0000000000C0")!,
                                name: "Custom", modes: [0: .constant(rpm: 3000)])
        let legacy = try legacyJSON(profiles: [custom, smoke, .silent(for: fans)], active: smoke.id)

        let store = try ProfileStore.decodeJSON(legacy)
        #expect(store.profiles.map(\.id) == FanProfile.fixedProfileIDs)
        #expect(store.profile(id: ID.custom1)?.modes == sensorModes)
        #expect(store.profile(id: ID.custom1)?.name == "Custom 1")
        #expect(store.profile(id: ID.custom2) == .defaultCustom2())
        #expect(store.activeProfileID == ID.custom1)
    }

    @Test func testLegacyMigrationDropsOthers() throws {
        let constant = FanProfile(name: "Mine", modes: [0: .constant(rpm: 2800)])
        // Active pointed at a dropped profile → Automatic (nil).
        var store = try ProfileStore.decodeJSON(legacyJSON(profiles: [constant, .maximum(for: fans)], active: constant.id))
        #expect(store == ProfileStore())
        // Active Silent / Maximum → nil; Automatic is kept.
        store = try ProfileStore.decodeJSON(legacyJSON(profiles: [], active: ID.maximum))
        #expect(store.activeProfileID == nil)
        store = try ProfileStore.decodeJSON(legacyJSON(profiles: [], active: ID.automatic))
        #expect(store.activeProfileID == ID.automatic)
        // An empty legacy object decodes to the default store.
        #expect(try ProfileStore.decodeJSON(Data("{}".utf8)) == ProfileStore())
    }

    @Test func testBoostPlan() {
        let profile = FanProfile.boost()
        func plan(_ cpu: Double?) -> [Int: Int?] {
            let sensors = cpu.map { [SensorReading(id: "agg:cpu", name: "CPU (max)", temperature: $0, sensorType: .greatest)] } ?? []
            return FanControlEngine.plan(profile: profile, fans: fans, sensors: sensors, policy: .default(appleSilicon: true),
                                         isEmergency: false)
        }
        #expect(plan(40) == [0: 2317, 1: 2317])
        #expect(plan(70) == [0: 2317, 1: 2317])
        // Mac14,9 idle hottest core (agg:cpu 72.7 °C): close to minimum, not near max.
        // 2317 + (72.7 − 70) / 25 × 4483 = 2801.2 → 2801
        #expect(plan(72.7) == [0: 2801, 1: 2801])
        // 82.5 °C = halfway: 2317 + (6800 − 2317) / 2 = 4558.5 → 4559 (rounded)
        #expect(plan(82.5) == [0: 4559, 1: 4559])
        #expect(plan(95) == [0: 6800, 1: 6800])
        #expect(plan(100) == [0: 6800, 1: 6800])
        // No agg:cpu reading → fail hot (max).
        #expect(plan(nil) == [0: 6800, 1: 6800])
        // Constant presets clamp into Mn…Mx and ignore sensors.
        let high = FanControlEngine.plan(profile: .constantHigh(), fans: fans, sensors: [], policy: .default, isEmergency: false)
        #expect(high == [0: 5000, 1: 5000])
        let quietOnSmallFan = FanControlEngine.plan(profile: .constantQuiet(),
                                                    fans: [FanDevice(id: 0, name: "F", minRPM: 1200, maxRPM: 2500)],
                                                    sensors: [], policy: .default, isEmergency: false)
        #expect(quietOnSmallFan == [0: 2500])
        // The emergency override still forces max over Automatic.
        let emergency = FanControlEngine.plan(profile: .automatic(), fans: fans, sensors: [], policy: .default, isEmergency: true)
        #expect(emergency == [0: 6800, 1: 6800])
    }

    private enum FanFile { static let ids = FanProfile.fixedProfileIDs }

    /// JSON as written by the pre-fixed-set `ProfileStore` (no `schemaVersion`).
    private func legacyJSON(profiles: [FanProfile], active: UUID?) throws -> Data {
        struct Legacy: Encodable { var profiles: [FanProfile]; var activeProfileID: UUID? }
        return try JSONEncoder().encode(Legacy(profiles: profiles, activeProfileID: active))
    }
}
