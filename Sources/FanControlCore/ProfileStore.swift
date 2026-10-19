import Foundation

/// Persistable collection of fan profiles plus the active selection.
public struct ProfileStore: Codable, Hashable, Sendable {
    public var profiles: [FanProfile]
    public var activeProfileID: UUID?

    public init(profiles: [FanProfile] = [], activeProfileID: UUID? = nil) {
        self.profiles = profiles
        self.activeProfileID = activeProfileID
    }

    /// The active profile, if `activeProfileID` refers to a stored profile.
    public var activeProfile: FanProfile? {
        guard let id = activeProfileID else { return nil }
        return profiles.first { $0.id == id }
    }

    /// Replaces the profile with the same id, or appends it.
    public mutating func upsert(_ profile: FanProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
    }

    /// Deletes the profile with `id`. Built-in profiles are never deleted.
    /// Clears `activeProfileID` if it pointed at the deleted profile.
    /// - Returns: `true` if a profile was removed.
    @discardableResult
    public mutating func delete(id: UUID) -> Bool {
        guard let index = profiles.firstIndex(where: { $0.id == id }),
              !profiles[index].isBuiltIn else { return false }
        profiles.remove(at: index)
        if activeProfileID == id { activeProfileID = nil }
        return true
    }

    /// Encodes the store as JSON (sorted keys for stable diffs).
    public static func encodeJSON(_ store: ProfileStore) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(store)
    }

    /// Decodes a store from JSON produced by `encodeJSON`.
    public static func decodeJSON(_ data: Data) throws -> ProfileStore {
        try JSONDecoder().decode(ProfileStore.self, from: data)
    }
}
