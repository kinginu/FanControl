import Foundation

// F2: Which automatic feature decides the active fan profile. Precedence (highest first):
//
//     manual > emergency > workload > power > default
//
// - manual: the user picked a profile themselves (widget, menu, settings).
// - emergency: an automatic claim that must beat the other automations (reserved; e.g. a
//   thermal rule). NOT the manager's 95 °C safety override, which works below the profile
//   layer (it forces every fan to maximum whatever profile is active) and always wins.
// - workload: per-app / workload profiles (F3).
// - power: power profiles (F2, `PowerProfileEngine`).
// - default: the profile the user had chosen last (the baseline automation returns to).
//
// Pure value type; `FanControlKit.FanProfileArbiter` applies the result.

/// A precedence layer. `Comparable` by precedence (`.manual` is the greatest).
public enum ProfileLayer: Int, Codable, Hashable, Sendable, CaseIterable, Comparable {
    case baseline = 0
    case power = 1
    case workload = 2
    case emergency = 3
    case manual = 4

    /// The layers automatic features claim through `ProfileArbitration.setClaim(_:for:)`.
    public static let automaticLayers: [ProfileLayer] = [.emergency, .workload, .power]

    public static func < (lhs: ProfileLayer, rhs: ProfileLayer) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Short English name for status lines ("Manual", "Power Profile", …).
    public var displayName: String {
        switch self {
        case .baseline: return "Default"
        case .power: return "Power Profile"
        case .workload: return "Workload"
        case .emergency: return "Emergency"
        case .manual: return "Manual"
        }
    }
}

/// One feature's wish: "activate this profile, because …".
public struct ProfileClaim: Hashable, Sendable {
    public var profileID: UUID
    /// Human-readable cause, e.g. the matching rule's name.
    public var reason: String

    public init(profileID: UUID, reason: String) {
        self.profileID = profileID
        self.reason = reason
    }
}

/// The winning layer and profile.
public struct ProfileDecision: Hashable, Sendable {
    public var layer: ProfileLayer
    public var profileID: UUID
    public var reason: String
}

/// Claims per layer plus the manual override and the baseline.
///
/// Manual override: `noteManualSelection(_:)` makes the user's pick win over every
/// automatic claim **until** the automatic winner changes to a different profile (a new
/// context: the next rule transition) or `resumeAutomation()` is called — so a manual
/// choice is respected until something actually changes, and automation then resumes by
/// itself. A manual pick also becomes the new baseline.
public struct ProfileArbitration: Hashable, Sendable {
    public private(set) var claims: [ProfileLayer: ProfileClaim] = [:]
    /// The user's manual pick, while it overrides the automatic claims.
    public private(set) var manualProfileID: UUID?
    /// Profile used when no layer claims anything (`nil` = no opinion: nothing is applied).
    public var baselineProfileID: UUID?
    /// `false` keeps a manual pick until `resumeAutomation()` (no automatic end).
    public var manualEndsOnTransition: Bool

    public init(baselineProfileID: UUID? = nil, manualEndsOnTransition: Bool = true) {
        self.baselineProfileID = baselineProfileID
        self.manualEndsOnTransition = manualEndsOnTransition
    }

    /// The highest automatic claim (emergency > workload > power).
    public var automaticWinner: ProfileDecision? {
        for layer in ProfileLayer.automaticLayers {
            if let claim = claims[layer] {
                return ProfileDecision(layer: layer, profileID: claim.profileID, reason: claim.reason)
            }
        }
        return nil
    }

    /// manual > automatic winner > baseline; `nil` when nobody has an opinion.
    public var decision: ProfileDecision? {
        if let manualProfileID {
            return ProfileDecision(layer: .manual, profileID: manualProfileID, reason: "Chosen manually")
        }
        if let automaticWinner { return automaticWinner }
        if let baselineProfileID {
            return ProfileDecision(layer: .baseline, profileID: baselineProfileID, reason: "Your profile")
        }
        return nil
    }

    /// Sets (or with `nil` withdraws) the claim of an automatic layer. Returns `true` if the
    /// claim changed. `.manual` / `.baseline` are ignored (use their own methods).
    ///
    /// `endsManualOverride: false` keeps a manual pick even if the automatic winner changes
    /// (a feature withdrawing a stale claim while it is paused by that very pick).
    @discardableResult
    public mutating func setClaim(_ claim: ProfileClaim?, for layer: ProfileLayer,
                                  endsManualOverride: Bool = true) -> Bool {
        guard ProfileLayer.automaticLayers.contains(layer), claims[layer] != claim else { return false }
        let before = automaticWinner?.profileID
        claims[layer] = claim
        if endsManualOverride, manualEndsOnTransition, manualProfileID != nil, automaticWinner?.profileID != before {
            manualProfileID = nil
        }
        return true
    }

    /// The user chose `profileID`: it overrides the automatic claims and becomes the baseline.
    public mutating func noteManualSelection(_ profileID: UUID) {
        baselineProfileID = profileID
        // Picking exactly what automation wants is not an override.
        manualProfileID = (automaticWinner?.profileID == profileID) ? nil : profileID
    }

    /// Ends the manual override (automation decides again).
    public mutating func resumeAutomation() {
        manualProfileID = nil
    }

    public var isManualOverrideActive: Bool { manualProfileID != nil }
}
