import Foundation

// Normalization (the fixed-seven invariant) and migration of older stores.

extension ProfileStore {

    /// The Custom 1 default before the curves (schema 2): `.sensor(agg:cpu, 70 → 95 °C)`.
    static let legacyCustom1Mode = FanControlMode.sensor(sensorKey: "agg:cpu", startTemperature: 70,
                                                         maxTemperature: 95)

    /// Schema 2 → 3: a stored Custom 1 that still equals the old factory default (name
    /// "Custom 1", `defaultMode` = `legacyCustom1Mode`, every `modes` entry the same, no
    /// curves) becomes the new default (`FanProfile.defaultCustom1()`).
    static func migratedCustom1(_ profiles: [FanProfile]) -> [FanProfile] {
        profiles.map { profile in
            guard profile.id == FanProfile.BuiltInID.custom1,
                  profile.name == FanProfile.DefaultName.custom1,
                  profile.defaultMode == legacyCustom1Mode,
                  profile.modes.values.allSatisfy({ $0 == legacyCustom1Mode }),
                  profile.curves.isEmpty, profile.defaultCurve == nil else { return profile }
            return FanProfile.defaultCustom1()
        }
    }

    /// A store built from a pre-fixed-set (schema 1) profile list.
    static func migratedFromLegacy(profiles legacy: [FanProfile], activeProfileID: UUID?) -> ProfileStore {
        var store = ProfileStore()
        let folded = legacy.first { profile in
            !profile.isBuiltIn && !FanProfile.fixedProfileIDs.contains(profile.id)
                && profile.modes.values.contains(where: \.isSensorBased)
        }
        if let folded {
            var custom1 = FanProfile.defaultCustom1()
            custom1.modes = folded.modes
            store.upsert(custom1)
        }
        switch activeProfileID {
        case .some(let id) where id == folded?.id:
            store.activeProfileID = FanProfile.BuiltInID.custom1
        case .some(let id) where id == FanProfile.BuiltInID.automatic:
            store.activeProfileID = id
        default:
            store.activeProfileID = nil
        }
        return store
    }

    /// The seven fixed profiles (presets from code, custom slots from
    /// `profiles` when present), then the additional profiles of `profiles`
    /// in their order (first occurrence of each id).
    static func normalized(_ profiles: [FanProfile]) -> [FanProfile] {
        let fixed = FanProfile.fixedProfileIDs.compactMap { id -> FanProfile? in
            if FanProfile.customSlotIDs.contains(id), let stored = profiles.first(where: { $0.id == id }) {
                return sanitizedSlot(stored)
            }
            return FanProfile.fixedDefault(id: id)
        }
        var seen = Set<UUID>()
        let additional = profiles.filter { isAdditional($0) && seen.insert($0.id).inserted }
        return fixed + additional
    }

    /// A user (non-built-in) profile whose id is not one of the seven (nor a legacy built-in id).
    static func isAdditional(_ profile: FanProfile) -> Bool {
        !profile.isBuiltIn && !FanProfile.fixedProfileIDs.contains(profile.id)
            && profile.id != FanProfile.BuiltInID.silent && profile.id != FanProfile.BuiltInID.maximum
    }

    /// `profile` with stale curves dropped and a two-point linear curve
    /// (`FanCurve.linear`) added for every `.sensor` mode (in `modes` or `defaultMode`)
    /// that has no matching curve. Degenerate modes (start ≥ max, non-finite) get none.
    static func withCurves(_ profile: FanProfile) -> FanProfile {
        var result = profile
        result.removeStaleCurves()
        for (fan, mode) in result.modes where result.curves[fan] == nil {
            result.curves[fan] = mode.linearCurve
        }
        if result.defaultCurve == nil {
            result.defaultCurve = result.defaultMode?.linearCurve
        }
        return result
    }

    /// `id` if it names a profile in `profiles`, else `nil` (Automatic).
    static func normalizedActiveID(_ id: UUID?, in profiles: [FanProfile]) -> UUID? {
        guard let id, profiles.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    /// A custom slot with `isBuiltIn == false`, a non-empty name and a matching curve for
    /// every `.sensor` mode (`withCurves`).
    static func sanitizedSlot(_ profile: FanProfile) -> FanProfile {
        var slot = withCurves(profile)
        slot.isBuiltIn = false
        let trimmed = slot.name.trimmingCharacters(in: .whitespacesAndNewlines)
        slot.name = trimmed.isEmpty ? (FanProfile.defaultName(id: slot.id) ?? slot.name) : slot.name
        return slot
    }
}
