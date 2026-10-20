import Foundation

/// Persistable store of the **fixed set of six** fan profiles plus the active selection.
///
/// `profiles` always starts with exactly `FanProfile.fixedProfileIDs`, in that
/// order (`fixedProfiles`; the only profiles the app UI shows):
///
/// | id (`FanProfile.BuiltInID`) | name | content | editable |
/// |---|---|---|---|
/// | `automatic` | Automatic | SMC default | no |
/// | `constantQuiet` | Constant Quiet | every fan 3000 RPM | no |
/// | `constantHigh` | Constant High | every fan 5000 RPM | no |
/// | `boost` | Boost | every fan follows `agg:cpu`, 70 → 95 °C | no |
/// | `custom1` | Custom 1 | default: copy of Boost | modes + name |
/// | `custom2` | Custom 2 | default: every fan 3500 RPM | modes + name |
///
/// Presets are always regenerated from code (`FanProfile.fixedDefault(id:)`),
/// so a stored preset never overrides a changed preset value; only the two
/// custom slots are persisted as edited. The six cannot be deleted:
/// `upsert` replaces a custom slot (presets are ignored), `delete` is a no-op
/// for them, `reset(id:)` restores a slot's default.
///
/// `additionalProfiles` (after the six) are *programmatic* profiles that
/// `FanControlManager` itself stores: the "Custom" profile of
/// `setFanRPM` / `setFanControlMode` (`FanControlManager.customProfileID`) and
/// profiles passed to `applyProfile` by tools such as HelperSmokeApp. They
/// are kept (so such a profile stays active across polls and launches) but
/// never shown by the app UI, which only offers the six. `upsert` adds or
/// replaces them and `delete` removes them.
///
/// Every mutation keeps the invariant (`profiles` / `activeProfileID` are
/// normalized in `didSet`): an `activeProfileID` that names no stored
/// profile becomes `nil`, which the manager resolves to Automatic.
///
/// Migration (stores written before the fixed set, i.e. JSON without
/// `schemaVersion`): the old built-ins Silent / Maximum are dropped; the first
/// user profile that has a sensor-linked mode is folded into Custom 1 (its
/// `modes` only; the name stays "Custom 1"); every other user profile is
/// dropped. An active selection that pointed at the folded profile becomes
/// Custom 1; one that pointed at Automatic stays; anything else becomes `nil`
/// (Automatic). The migrated store is written back on the next change.
public struct ProfileStore: Codable, Hashable, Sendable {

    /// Version written by `encode(to:)`. Absent (= 1) in stores from before the fixed set.
    public static let schemaVersion = 2

    /// The six fixed profiles in display order, then `additionalProfiles`
    /// (normalized on every assignment).
    public var profiles: [FanProfile] {
        didSet {
            profiles = Self.normalized(profiles)
            activeProfileID = Self.normalizedActiveID(activeProfileID, in: profiles)
        }
    }
    /// The active profile id; `nil` (or an id of no stored profile, which is
    /// normalized to `nil`) means Automatic.
    public var activeProfileID: UUID? {
        didSet { activeProfileID = Self.normalizedActiveID(activeProfileID, in: profiles) }
    }

    /// A store with the six fixed profiles. Custom slots found in `profiles`
    /// keep their content; stored presets are replaced by their definition;
    /// other user profiles are kept as `additionalProfiles` (no legacy
    /// folding; that happens only when decoding an old store).
    public init(profiles: [FanProfile] = [], activeProfileID: UUID? = nil) {
        let normalized = Self.normalized(profiles)
        self.profiles = normalized
        self.activeProfileID = Self.normalizedActiveID(activeProfileID, in: normalized)
    }

    /// The six fixed profiles (`FanProfile.fixedProfileIDs` order). The app UI shows only these.
    public var fixedProfiles: [FanProfile] { Array(profiles.prefix(FanProfile.fixedProfileIDs.count)) }

    /// Programmatic profiles stored by `FanControlManager` (`setFanRPM`'s
    /// "Custom", tool profiles); not shown by the app UI.
    public var additionalProfiles: [FanProfile] { Array(profiles.dropFirst(FanProfile.fixedProfileIDs.count)) }

    /// The active profile, if `activeProfileID` refers to a stored profile.
    public var activeProfile: FanProfile? {
        guard let id = activeProfileID else { return nil }
        return profile(id: id)
    }

    /// The stored profile with `id`.
    public func profile(id: UUID) -> FanProfile? {
        profiles.first { $0.id == id }
    }

    /// Replaces a custom slot (Custom 1 / Custom 2) with `profile` (its modes,
    /// `defaultMode` and name; an empty / whitespace-only name becomes the
    /// slot's default name), or adds / replaces a programmatic
    /// `additionalProfiles` entry. Presets and other built-ins (legacy
    /// Silent / Maximum) are ignored.
    /// - Returns: `true` if a profile was stored.
    @discardableResult
    public mutating func upsert(_ profile: FanProfile) -> Bool {
        if profile.isCustomSlot, let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = Self.sanitizedSlot(profile)
            return true
        }
        guard Self.isAdditional(profile) else { return false }
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        return true
    }

    /// Renames a custom slot (name only). An empty / whitespace-only name
    /// restores the default name. Presets cannot be renamed.
    /// - Returns: `true` if a slot was renamed.
    @discardableResult
    public mutating func rename(id: UUID, to name: String) -> Bool {
        guard var slot = profile(id: id), slot.isCustomSlot else { return false }
        slot.name = name
        return upsert(slot)
    }

    /// Restores a custom slot to its default content and name
    /// (`FanProfile.defaultCustom1()` / `defaultCustom2()`). The active
    /// selection is kept. Presets are always at their default.
    /// - Returns: `true` if `id` is a custom slot.
    @discardableResult
    public mutating func reset(id: UUID) -> Bool {
        guard FanProfile.customSlotIDs.contains(id), let fresh = FanProfile.fixedDefault(id: id) else { return false }
        return upsert(fresh)
    }

    /// `true` if fixed profile `id` differs from its factory default (always
    /// `false` for presets). Compares the effective mode of every fan in
    /// `fans` and the name, so a slot whose `defaultMode` was materialized
    /// into per-fan `modes` (`FanProfile.resolved(for:)`) but is otherwise
    /// unchanged is not "modified". With `fans` empty, compares the stored values.
    public func isModified(id: UUID, fans: [FanDevice] = []) -> Bool {
        guard let stored = profile(id: id), let fresh = FanProfile.fixedDefault(id: id) else { return false }
        if stored.name != fresh.name { return true }
        if fans.isEmpty { return stored.modes != fresh.modes || stored.defaultMode != fresh.defaultMode }
        return fans.contains { stored.mode(for: $0) != fresh.mode(for: $0) }
    }

    /// Deletes a programmatic `additionalProfiles` entry (clearing
    /// `activeProfileID` if it pointed at it). The six fixed profiles are
    /// never deleted (use `reset(id:)` for a custom slot).
    /// - Returns: `true` if a profile was removed.
    @discardableResult
    public mutating func delete(id: UUID) -> Bool {
        guard !FanProfile.fixedProfileIDs.contains(id), profiles.contains(where: { $0.id == id }) else { return false }
        profiles.removeAll { $0.id == id }
        return true
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, profiles, activeProfileID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        let stored = try container.decodeIfPresent([FanProfile].self, forKey: .profiles) ?? []
        let active = try container.decodeIfPresent(UUID.self, forKey: .activeProfileID)
        if version >= 2 {
            self.init(profiles: stored, activeProfileID: active)
        } else {
            self = Self.migratedFromLegacy(profiles: stored, activeProfileID: active)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schemaVersion, forKey: .schemaVersion)
        try container.encode(profiles, forKey: .profiles)
        try container.encodeIfPresent(activeProfileID, forKey: .activeProfileID)
    }

    /// Encodes the store as JSON (sorted keys for stable diffs).
    public static func encodeJSON(_ store: ProfileStore) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(store)
    }

    /// Decodes a store from JSON produced by `encodeJSON` (migrating stores
    /// from before the fixed set; see the type documentation).
    public static func decodeJSON(_ data: Data) throws -> ProfileStore {
        try JSONDecoder().decode(ProfileStore.self, from: data)
    }

    // MARK: Normalization / migration

    /// A store built from a pre-fixed-set (schema 1) profile list.
    static func migratedFromLegacy(profiles legacy: [FanProfile], activeProfileID: UUID?) -> ProfileStore {
        var store = ProfileStore()
        let folded = legacy.first { profile in
            !profile.isBuiltIn && !FanProfile.fixedProfileIDs.contains(profile.id)
                && profile.modes.values.contains { if case .sensor = $0 { return true } else { return false } }
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

    /// The six fixed profiles (presets from code, custom slots from
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

    /// A user (non-built-in) profile whose id is not one of the six (nor a legacy built-in id).
    static func isAdditional(_ profile: FanProfile) -> Bool {
        !profile.isBuiltIn && !FanProfile.fixedProfileIDs.contains(profile.id)
            && profile.id != FanProfile.BuiltInID.silent && profile.id != FanProfile.BuiltInID.maximum
    }

    static func normalizedActiveID(_ id: UUID?, in profiles: [FanProfile]) -> UUID? {
        guard let id, profiles.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    /// A custom slot with `isBuiltIn == false` and a non-empty name.
    static func sanitizedSlot(_ profile: FanProfile) -> FanProfile {
        var slot = profile
        slot.isBuiltIn = false
        let trimmed = slot.name.trimmingCharacters(in: .whitespacesAndNewlines)
        slot.name = trimmed.isEmpty ? (FanProfile.defaultName(id: slot.id) ?? slot.name) : slot.name
        return slot
    }
}
