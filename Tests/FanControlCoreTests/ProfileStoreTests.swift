import Foundation
import Testing
@testable import FanControlCore

/// The fixed set of seven profiles (`ProfileStore`, docs/kit.md "Profiles").
@Suite("Profile store", .tags(.profiles))
struct ProfileStoreTests {
    typealias ID = FanProfile.BuiltInID

    let fans = Fixtures.mac14_9Fans

    @Test func fixedSetAndOrder() {
        let store = ProfileStore()
        #expect(store.profiles.map(\.id) == FanProfile.fixedProfileIDs)
        #expect(store.profiles.map(\.id) == [ID.automatic, ID.constantQuiet, ID.constantHigh, ID.boost,
                                             ID.max, ID.custom1, ID.custom2])
        #expect(store.profiles.map(\.name) == ["Automatic", "Constant Quiet", "Constant High", "Boost",
                                               "Max", "Custom 1", "Custom 2"])
        #expect(store.profiles.map(\.isBuiltIn) == [true, true, true, true, true, false, false])
        #expect(store.profiles.map(\.isCustomSlot) == [false, false, false, false, false, true, true])
        #expect(Set(FanProfile.fixedProfileIDs).count == 7)
        #expect(ID.max != ID.maximum)
        #expect(!FanProfile.fixedProfileIDs.contains(ID.silent))
        #expect(!FanProfile.fixedProfileIDs.contains(ID.maximum))
        #expect(store.activeProfileID == nil)
    }

    @Test func presetDefaults() {
        for fan in fans {
            #expect(FanProfile.automatic().mode(for: fan) == .automatic, "\(fan.name)")
            #expect(FanProfile.constantQuiet().mode(for: fan) == .constant(rpm: 3000))
            #expect(FanProfile.constantHigh().mode(for: fan) == .constant(rpm: 5000))
            #expect(FanProfile.boost().mode(for: fan)
                    == .sensor(sensorKey: "agg:cpu", startTemperature: 50, maxTemperature: 85))
            #expect(FanProfile.boost().curve(for: fan) == FanCurve.boost)
            #expect(FanProfile.max().mode(for: fan) == .constant(rpm: 6800))
            #expect(FanProfile.defaultCustom1().mode(for: fan) == FanProfile.boost().mode(for: fan))
            #expect(FanProfile.defaultCustom1().curve(for: fan) == FanProfile.boost().curve(for: fan))
            #expect(FanProfile.defaultCustom2().mode(for: fan) == .constant(rpm: 3500))
        }
        #expect(FanProfile.fixedDefault(id: UUID()) == nil)
        #expect(FanProfile.fixedDefault(id: ID.boost) == .boost())
        #expect(FanProfile.fixedDefault(id: ID.max) == .max())
        #expect(FanCurve.boost.points.map(\.temperature) == [50, 60, 70, 80, 85])
        #expect(FanCurve.boost.points.map(\.rpm) == [0, 3500, 5200, 6400, 6800])
    }

    @Test func modeFallbackAndResolved() {
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

    @Test func presetsAreReadOnly() {
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
        #expect(store.profiles.count == 7)
        // Direct assignment is normalized as well.
        store.profiles.removeAll { $0.id == ID.custom2 }
        store.profiles[2] = FanProfile(id: ID.constantHigh, name: "Hacked", defaultMode: .constant(rpm: 1))
        store.profiles.insert(.silent(for: fans), at: 0)
        #expect(store.profiles == ProfileStore().profiles)
    }

    @Test func editRenameReset() {
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

    @Test func deleteIsNoOpAndActiveNormalized() {
        var store = ProfileStore()
        for id in FanProfile.fixedProfileIDs { #expect(store.delete(id: id) == false) }
        #expect(store.profiles.count == 7)
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
    @Test func additionalProfiles() throws {
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

    @Test func codableRoundTrip() throws {
        var store = ProfileStore()
        store.rename(id: ID.custom1, to: "Gaming")
        var custom2 = store.profile(id: ID.custom2)!
        custom2.modes = [1: .constant(rpm: 2600)]
        store.upsert(custom2)
        store.activeProfileID = ID.custom1

        let data = try ProfileStore.encodeJSON(store)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"schemaVersion\" : 3"))
        let decoded = try ProfileStore.decodeJSON(data)
        #expect(decoded == store)
        #expect(decoded.profile(id: ID.custom1)?.name == "Gaming")
        #expect(decoded.profile(id: ID.custom2)?.mode(for: fans[1]) == .constant(rpm: 2600))
        #expect(decoded.profile(id: ID.custom2)?.mode(for: fans[0]) == .constant(rpm: 3500))
    }

    @Test func storedPresetIsRegeneratedFromCode() throws {
        // A v2 store whose preset values differ (e.g. written by an older build) gets today's presets.
        let stale = ProfileStore()
        var json = String(data: try ProfileStore.encodeJSON(stale), encoding: .utf8)!
        json = json.replacingOccurrences(of: "\"rpm\" : 3000", with: "\"rpm\" : 1234")
        #expect(json.contains("1234"))
        let decoded = try ProfileStore.decodeJSON(Data(json.utf8))
        #expect(decoded.profile(id: ID.constantQuiet) == .constantQuiet())
    }

    @Test func legacyMigrationFoldsSensorProfile() throws {
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

    @Test func legacyMigrationDropsOthers() throws {
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

    @Test func boostPlan() {
        let profile = FanProfile.boost()
        func plan(_ cpu: Double?) -> [Int: Int?] {
            let sensors = cpu.map { [SensorReading(id: "agg:cpu", name: "CPU (max)", temperature: $0, sensorType: .greatest)] } ?? []
            return FanControlEngine.plan(profile: profile, fans: fans, sensors: sensors, policy: .default,
                                         isEmergency: false)
        }
        #expect(plan(40) == [0: 2317, 1: 2317])
        #expect(plan(50) == [0: 2317, 1: 2317])
        // The curve passes through its points.
        #expect(plan(60) == [0: 3500, 1: 3500])
        #expect(plan(70) == [0: 5200, 1: 5200])
        #expect(plan(80) == [0: 6400, 1: 6400])
        #expect(plan(85) == [0: 6800, 1: 6800])
        // Between points: strictly between the neighbours (monotone cubic).
        let mid = plan(72.7)[0]!!
        #expect(mid > 5200 && mid < 6400)
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

/// Schema 3 (2026-10-20): curves in custom slots, Max preset, Custom 1 migration.
@Suite("Profile store curves", .tags(.profiles, .control))
struct ProfileStoreCurveTests {
    typealias ID = FanProfile.BuiltInID
    let fans = Fixtures.mac14_9Fans

    /// A schema-2 store JSON with `custom1` as the Custom 1 slot.
    private func schema2JSON(custom1: FanProfile, active: UUID? = nil) throws -> Data {
        struct V2: Encodable { var schemaVersion = 2; var profiles: [FanProfile]; var activeProfileID: UUID? }
        return try JSONEncoder().encode(V2(profiles: [custom1, .defaultCustom2()], activeProfileID: active))
    }

    @Test func unchangedOldCustom1BecomesBoostCurve() throws {
        let old = FanProfile(id: ID.custom1, name: "Custom 1", defaultMode: ProfileStore.legacyCustom1Mode)
        var store = try ProfileStore.decodeJSON(schema2JSON(custom1: old, active: ID.custom1))
        #expect(store.profile(id: ID.custom1) == .defaultCustom1())
        #expect(store.activeProfileID == ID.custom1)
        #expect(store.profiles.map(\.id) == FanProfile.fixedProfileIDs)
        // Materialized (resolved) old default is migrated as well.
        let resolvedOld = old.resolved(for: fans)
        store = try ProfileStore.decodeJSON(schema2JSON(custom1: FanProfile(
            id: ID.custom1, name: "Custom 1", modes: resolvedOld.modes, defaultMode: old.defaultMode)))
        #expect(store.profile(id: ID.custom1) == .defaultCustom1())
    }

    @Test func editedStartMaxSlotGetsTwoPointCurve() throws {
        let edited = FanProfile(id: ID.custom1, name: "Gaming",
                                modes: [0: .sensor(sensorKey: "agg:gpu", startTemperature: 45, maxTemperature: 75),
                                        1: .constant(rpm: 3000)],
                                defaultMode: ProfileStore.legacyCustom1Mode)
        let store = try ProfileStore.decodeJSON(schema2JSON(custom1: edited))
        let slot = try #require(store.profile(id: ID.custom1))
        #expect(slot.name == "Gaming")
        #expect(slot.modes == edited.modes)
        #expect(slot.curves == [0: .linear(startTemperature: 45, maxTemperature: 75)])
        #expect(slot.defaultCurve == .linear(startTemperature: 70, maxTemperature: 95))
        // Behaviour unchanged: the two-point curve is the old linear ramp.
        let sensors = [SensorReading(id: "agg:gpu", name: "GPU", temperature: 60)]
        #expect(FanControlEngine.plan(profile: slot, fans: fans, sensors: sensors, policy: .default,
                                      isEmergency: false)[0] == 4559)
        // Round trip as schema 3 keeps it.
        #expect(try ProfileStore.decodeJSON(ProfileStore.encodeJSON(store)) == store)
    }

    @Test func curveUnawareEditReplacesStaleCurve() {
        var store = ProfileStore()
        var slot = store.profile(id: ID.custom1)!.resolved(for: fans)
        #expect(slot.curves[0] == .boost)
        // Old editor moves the start temperature only.
        slot.modes[0] = .sensor(sensorKey: "agg:cpu", startTemperature: 55, maxTemperature: 85)
        store.upsert(slot)
        let stored = store.profile(id: ID.custom1)!
        #expect(stored.curves[0] == .linear(startTemperature: 55, maxTemperature: 85))
        #expect(stored.curves[1] == .boost)
        #expect(store.isModified(id: ID.custom1, fans: fans))
        // A custom curve set with `setCurve` is kept.
        var custom = stored
        custom.setCurve(FanCurve([(40, 2400), (65, 5000), (75, 6800)]), sensorKey: "agg:cpu", forFan: 1)
        store.upsert(custom)
        #expect(store.profile(id: ID.custom1)?.curves[1] == FanCurve([(40, 2400), (65, 5000), (75, 6800)]))
        let didReset = store.reset(id: ID.custom1)
        #expect(didReset)
        #expect(!store.isModified(id: ID.custom1, fans: fans))
        #expect(!store.isModified(id: ID.custom1))
    }

    @Test func maxPreset() {
        let plan = FanControlEngine.plan(profile: .max(), fans: fans + [FanDevice(id: 2, name: "S", minRPM: 1000, maxRPM: 5000)],
                                         sensors: [], policy: .default, isEmergency: false)
        #expect(plan == [0: 6800, 1: 6800, 2: 5000])
        var store = ProfileStore()
        #expect(store.upsert(FanProfile(id: ID.max, name: "Hacked", defaultMode: .constant(rpm: 1))) == false)
        #expect(store.delete(id: ID.max) == false)
        #expect(store.profile(id: ID.max) == .max())
    }
}
