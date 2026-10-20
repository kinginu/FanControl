import Foundation

/// Whether the "Nook hidden" pause is in effect (`FanControlManager.isPauseInEffect`).
///
/// - `requested`: the host's Nook visibility (`setMonitoringPaused`): `true` while hidden.
/// - `holders`: views that need live data whatever the Nook state, e.g. the
///   settings pane (`setLiveDataHold(_:for:)`). While any hold exists the pause is
///   not in effect, so polling runs at the normal interval.
///
/// Holds are a set keyed by holder name, so nested / repeated appear-disappear
/// pairs from different views do not undo each other, and a repeated `true`
/// from the same holder is idempotent.
struct MonitoringPauseState: Equatable, Sendable {
    var requested: Bool = false
    private(set) var holders: Set<String> = []

    var isInEffect: Bool { requested && holders.isEmpty }

    mutating func setHold(_ held: Bool, for holder: String) {
        if held {
            holders.insert(holder)
        } else {
            holders.remove(holder)
        }
    }
}
