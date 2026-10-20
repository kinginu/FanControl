import FanControlCore

/// Poll-time check, while a write session is open, for fans whose SMC state does
/// not match what the manager last wrote (pure; unit-tested with plain values).
///
/// Motivation: across a sleep the SMC resets `F<n>Tg` to 0 but keeps `F<n>Md` = 1
/// (`docs/verification/first-write-2026-10-20.md` テスト 4), so a fan can sit in
/// manual mode at target 0 (stopped) while the throttle baseline (`appliedTargets`)
/// still says "applied". A fan reported here is added to the manager's
/// `unsettledFans`, so the next poll writes its planned state regardless of the
/// throttle (`FanControlManager.changedTargetsOnQueue`).
enum UnsettledFanDetector {

    /// A manual fan whose `F<n>Tg` differs from the applied target by more than
    /// this (RPM) is unsettled. Larger than `FanControlManager.writeThresholdRPM`
    /// rounding, small enough to catch a reset.
    static let targetToleranceRPM = 50

    /// What the poll read for one fan.
    struct Observation: Equatable, Sendable {
        /// `F<n>Md` ≠ 0 / `FS! ` bit set (`nil`: unknown, e.g. a target-only fan).
        var isManual: Bool?
        /// `F<n>Tg` in RPM (`nil`: unreadable).
        var targetRPM: Int?
    }

    /// Fans (among `fans`, controllable per `styles`) that are unsettled:
    /// 1. in manual mode with `F<n>Tg` below the hardware minimum (stopped in
    ///    manual, the post-wake state), whatever was applied;
    /// 2. applied `.manual(rpm)` but the SMC reports automatic (mode-key /
    ///    force-bit fans), or `F<n>Tg` off by more than `targetToleranceRPM`;
    /// 3. applied `.automatic` but the SMC reports manual mode.
    /// Fans never written in this session (no `applied` entry) only trip rule 1.
    static func unsettledFans(fans: [FanDevice],
                              styles: [Int: FanWriteStrategy.ControlStyle],
                              applied: [Int: FanTarget],
                              observed: [Int: Observation]) -> Set<Int> {
        var result = Set<Int>()
        for fan in fans {
            guard let style = styles[fan.id], let seen = observed[fan.id] else { continue }
            let modeKnown = style != .targetOnly
            let manual = modeKnown ? seen.isManual : nil

            if manual == true, let tg = seen.targetRPM, tg < fan.minRPM - targetToleranceRPM {
                result.insert(fan.id)
                continue
            }
            switch applied[fan.id] {
            case .manual(let rpm)?:
                if manual == false {
                    result.insert(fan.id)
                } else if let tg = seen.targetRPM, abs(tg - rpm) > targetToleranceRPM {
                    result.insert(fan.id)
                }
            case .automatic?:
                if manual == true { result.insert(fan.id) }
            case nil:
                break
            }
        }
        return result
    }
}
