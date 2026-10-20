#if os(macOS)
// The seven fixed fan profiles as the UI lists them, and the one way the UI applies a profile.

import Foundation
import FanControlCore
import FanControlKit

// MARK: - Fixed profiles (the seven of `ProfileStore`)

public enum FanControlProfiles {

    /// The seven fixed profiles in display order (`ProfileStore.fixedProfiles`: Automatic,
    /// Constant Quiet, Constant High, Boost, Max, Custom 1, Custom 2).
    /// `FanControlManager.availableProfiles` still lists the legacy
    /// Silent / Maximum built-ins and programmatic profiles (`setFanRPM`'s
    /// "Custom"), so the UI reads the store's fixed seven instead.
    @MainActor
    public static var all: [FanProfile] { FanControlManager.shared.profileStore.fixedProfiles }

    /// The active profile's id; Automatic when nothing is selected. May be a
    /// programmatic profile outside the seven (then no selector entry is checked).
    @MainActor
    public static var activeID: UUID {
        FanControlManager.shared.profileStore.activeProfileID ?? FanProfile.BuiltInID.automatic
    }

    /// The active profile (Automatic when nothing is selected).
    @MainActor
    public static var active: FanProfile {
        FanControlManager.shared.profileStore.activeProfile ?? .automatic()
    }

    /// Applies `profile` with explicit per-fan modes (`FanProfile.resolved(for:)`):
    /// `applyProfile` opens the write session only when `modes` holds a manual
    /// mode, and the presets define theirs through `defaultMode`.
    @MainActor
    public static func apply(_ profile: FanProfile) async throws {
        let manager = FanControlManager.shared
        try await manager.applyProfile(profile.resolved(for: manager.fans))
    }
}
#endif
