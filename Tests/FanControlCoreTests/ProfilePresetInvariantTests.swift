import Foundation
import Testing
@testable import FanControlCore

/// Invariants of the fixed profiles, their presets and `ProfileStore` normalization.
struct ProfilePresetInvariantTests {
    typealias ID = FanProfile.BuiltInID
    let fans = [
        FanDevice(id: 0, name: "Fan 1", minRPM: 2317, maxRPM: 6800),
        FanDevice(id: 1, name: "Fan 2", minRPM: 2317, maxRPM: 6800),
    ]

    var fixedDefaults: [FanProfile] { FanProfile.fixedProfileIDs.compactMap { FanProfile.fixedDefault(id: $0) } }

    @Test func testFixedIdentifiers() {
        let ids = FanProfile.fixedProfileIDs
        #expect(ids.count == 7)
        #expect(Set(ids).count == ids.count)
        #expect(Set(FanProfile.customSlotIDs).isSubset(of: Set(ids)))
        #expect(!ids.contains(ID.silent) && !ids.contains(ID.maximum))
        #expect(fixedDefaults.map(\.id) == ids)
        #expect(FanProfile.fixedDefault(id: ID.silent) == nil)
        #expect(FanProfile.fixedDefault(id: UUID()) == nil)
        #expect(FanProfile.defaultName(id: UUID()) == nil)
    }

    @Test func testBuiltInFlagsAndNames() {
        let names = [FanProfile.DefaultName.automatic, FanProfile.DefaultName.constantQuiet,
                     FanProfile.DefaultName.constantHigh, FanProfile.DefaultName.boost, FanProfile.DefaultName.max,
                     FanProfile.DefaultName.custom1, FanProfile.DefaultName.custom2]
        #expect(fixedDefaults.map(\.name) == names)
        #expect(Set(names).count == names.count)
        for profile in fixedDefaults {
            #expect(profile.isCustomSlot == FanProfile.customSlotIDs.contains(profile.id))
            #expect(profile.isBuiltIn == !profile.isCustomSlot)
            #expect(FanProfile.defaultName(id: profile.id) == profile.name)
            // Factories are pure.
            #expect(FanProfile.fixedDefault(id: profile.id) == profile)
        }
    }

    @Test func testPresetParameters() {
        typealias P = FanProfile.Preset
        #expect(P.quietRPM < P.custom2RPM && P.custom2RPM < P.highRPM && P.highRPM < P.maxRPM)
        #expect(P.boostStartTemperature < P.boostMaxTemperature)
        // Boost reaches full speed before the emergency override takes over.
        #expect(P.boostMaxTemperature < SafetyPolicy.default.emergencyTemperature)
        #expect(P.boostCurve == FanCurve.boost)
        #expect(P.boostCurve.startTemperature == P.boostStartTemperature)
        #expect(P.boostCurve.endTemperature == P.boostMaxTemperature)
        #expect(P.boostCurve.isValid())
        #expect(P.boostCurve.points.last?.rpm == P.maxRPM)
    }

    /// Each fixed profile's effective mode and curve for a real fan.
    @Test func testEffectiveModesAndCurves() {
        for profile in fixedDefaults {
            for fan in fans {
                let mode = profile.mode(for: fan)
                if case .sensor = mode {
                    let curve = profile.curve(for: fan)
                    #expect(curve == FanCurve.boost, "\(profile.name)")
                    #expect(FanControlEngine.controlSensorKeys(profile: profile, fans: [fan])
                        == [FanProfile.Preset.boostSensorKey])
                } else {
                    #expect(profile.curve(for: fan) == nil, "\(profile.name)")
                }
            }
        }
        let fan = fans[0]
        #expect(FanProfile.automatic().mode(for: fan) == .automatic)
        #expect(FanProfile.constantQuiet().mode(for: fan) == .constant(rpm: 3000))
        #expect(FanProfile.constantHigh().mode(for: fan) == .constant(rpm: 5000))
        #expect(FanProfile.max().mode(for: fan) == .constant(rpm: 6800))
        #expect(FanProfile.defaultCustom2().mode(for: fan) == .constant(rpm: 3500))
        #expect(FanProfile.defaultCustom1().mode(for: fan) == FanProfile.boost().mode(for: fan))
        #expect(FanProfile.defaultCustom1().curve(for: fan) == FanProfile.boost().curve(for: fan))
    }

    @Test func testFixedDefaultsRoundTripThroughJSON() throws {
        for profile in fixedDefaults {
            let decoded = try JSONDecoder().decode(FanProfile.self, from: JSONEncoder().encode(profile))
            #expect(decoded == profile)
        }
    }

    @Test func testResolvedIsIdempotentAndKeepsBehaviour() {
        for profile in fixedDefaults {
            let resolved = profile.resolved(for: fans)
            #expect(resolved.resolved(for: fans) == resolved)
            for fan in fans {
                #expect(resolved.mode(for: fan) == profile.mode(for: fan))
                #expect(resolved.curve(for: fan) == profile.curve(for: fan))
            }
        }
    }

    @Test func testLegacyBuiltInsToleratesDuplicateFanIDs() {
        let duplicated = fans + [FanDevice(id: 0, name: "Dup", minRPM: 1000, maxRPM: 2000)]
        #expect(FanProfile.silent(for: duplicated).modes == [0: .constant(rpm: 2317), 1: .constant(rpm: 2317)])
        #expect(FanProfile.maximum(for: duplicated).modes == [0: .constant(rpm: 6800), 1: .constant(rpm: 6800)])
    }

    // MARK: Modes and curves

    @Test func testLinearCurveOfModes() {
        #expect(FanControlMode.automatic.linearCurve == nil)
        #expect(FanControlMode.constant(rpm: 3000).linearCurve == nil)
        #expect(FanControlMode.sensor(sensorKey: "k", startTemperature: 60, maxTemperature: 60).linearCurve == nil)
        #expect(FanControlMode.sensor(sensorKey: "k", startTemperature: 70, maxTemperature: 60).linearCurve == nil)
        #expect(FanControlMode.sensor(sensorKey: "k", startTemperature: .nan, maxTemperature: 60).linearCurve == nil)
        #expect(FanControlMode.sensor(sensorKey: "k", startTemperature: 40, maxTemperature: .infinity)
            .linearCurve == nil)
        #expect(FanControlMode.sensor(sensorKey: "k", startTemperature: 40, maxTemperature: 80).linearCurve
            == .linear(startTemperature: 40, maxTemperature: 80))
        #expect(FanControlMode.sensor(sensorKey: "k", startTemperature: 40, maxTemperature: 80).isSensorBased)
        #expect(!FanControlMode.constant(rpm: 1).isSensorBased)
    }

    @Test func testDegenerateSensorModeHasNoCurve() {
        let fan = fans[0]
        let profile = FanProfile(name: "x", modes: [0: .sensor(sensorKey: "k", startTemperature: 80, maxTemperature: 80)])
        #expect(profile.curve(for: fan) == nil)
        // The engine then steps between minimum and maximum.
        #expect(FanControlEngine.targetRPM(for: profile, fan: fan, sensorTemperature: 79, policy: .default) == 2317)
        #expect(FanControlEngine.targetRPM(for: profile, fan: fan, sensorTemperature: 81, policy: .default) == 6800)
    }

    @Test func testRemoveStaleCurvesKeepsOnlyMatchingCurves() {
        var profile = FanProfile(
            name: "x",
            modes: [0: .sensor(sensorKey: "k", startTemperature: 50, maxTemperature: 85),
                    1: .sensor(sensorKey: "k", startTemperature: 40, maxTemperature: 85),
                    2: .constant(rpm: 3000)],
            defaultMode: .constant(rpm: 3000),
            curves: [0: .boost, 1: .boost, 2: .boost, 3: .boost],
            defaultCurve: .boost)
        profile.removeStaleCurves()
        #expect(profile.curves == [0: .boost])
        #expect(profile.defaultCurve == nil)

        var matching = FanProfile(name: "y", defaultMode: FanProfile.Preset.boostMode, defaultCurve: .boost)
        matching.removeStaleCurves()
        #expect(matching.defaultCurve == .boost)
    }

    @Test func testSetCurveIgnoresEmptyCurve() {
        var profile = FanProfile.defaultCustom2()
        profile.setCurve(FanCurve(points: [.init(temperature: .nan, rpm: 1)]), sensorKey: "k", forFan: nil)
        #expect(profile == FanProfile.defaultCustom2())
        profile.setCurve(FanCurve([(90, 6000), (40, 2000)]), sensorKey: "k", forFan: 1)
        #expect(profile.modes[1] == .sensor(sensorKey: "k", startTemperature: 40, maxTemperature: 90))
        #expect(profile.curves[1]?.points.map(\.temperature) == [40, 90])
        #expect(profile.curve(for: fans[1]) == profile.curves[1])
    }

    // MARK: Store invariant

    /// Whatever is assigned, the store starts with the seven fixed profiles in order and
    /// keeps a valid (or `nil`) active id.
    @Test func testStoreInvariantUnderArbitraryAssignments() {
        var store = ProfileStore()
        let extra = FanProfile(name: "Tool", modes: [0: .constant(rpm: 4000)])
        var hijacked = FanProfile.boost()
        hijacked.defaultMode = .constant(rpm: 1)
        var unnamed = FanProfile.defaultCustom2()
        unnamed.name = "   "
        unnamed.isBuiltIn = true
        let assignments: [[FanProfile]] = [
            [], [extra], [extra, extra], [hijacked], [unnamed, extra],
            [.silent(for: fans), .maximum(for: fans)], fixedDefaults.reversed(),
        ]
        for profiles in assignments {
            store.profiles = profiles
            store.activeProfileID = extra.id
            #expect(store.fixedProfiles.map(\.id) == FanProfile.fixedProfileIDs)
            #expect(store.profile(id: ID.boost) == FanProfile.boost())
            #expect(Set(store.profiles.map(\.id)).count == store.profiles.count)
            #expect(store.activeProfileID == nil || store.profile(id: store.activeProfileID!) != nil)
            #expect(store.additionalProfiles.allSatisfy { !$0.isBuiltIn })
            for slot in store.fixedProfiles where slot.isCustomSlot {
                #expect(!slot.isBuiltIn)
                #expect(!slot.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        store.profiles = [unnamed]
        #expect(store.profile(id: ID.custom2)?.name == FanProfile.DefaultName.custom2)
    }

    /// A custom slot's `.sensor` modes always carry a matching curve after sanitizing.
    @Test func testSanitizedSlotHasMatchingCurves() throws {
        var slot = FanProfile.defaultCustom1()
        slot.modes = [0: .sensor(sensorKey: "k", startTemperature: 45, maxTemperature: 75),
                      1: .sensor(sensorKey: "k", startTemperature: 75, maxTemperature: 45)]
        slot.defaultMode = .sensor(sensorKey: "k", startTemperature: 55, maxTemperature: 95)
        let store = ProfileStore(profiles: [slot])
        let stored = try #require(store.profile(id: ID.custom1))
        #expect(stored.curves[0] == .linear(startTemperature: 45, maxTemperature: 75))
        #expect(stored.curves[1] == nil)
        #expect(stored.defaultCurve == .linear(startTemperature: 55, maxTemperature: 95))
        #expect(!store.isModified(id: ID.boost))
        #expect(store.isModified(id: ID.custom1, fans: fans))
    }
}
