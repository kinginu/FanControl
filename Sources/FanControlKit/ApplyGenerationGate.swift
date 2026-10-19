/// Drop rule for poll-driven write batches (see `FanControlManager`).
///
/// Every user-initiated change of the planning source (applying a profile,
/// restoring automatic control, closing the session) calls `advance()` on the
/// queue that owns the gate *before* it writes. A poll batch records `current`
/// when it is planned; when the batch reaches the front of the write queue it
/// is dropped if `isStale(_:)` says a newer apply started in between, so a poll
/// planned from the previous profile can never undo the user's apply.
///
/// Pure value type (no locking): use it from a single serial queue.
struct ApplyGenerationGate: Equatable, Sendable {
    /// Generation of the latest apply (0 = none yet).
    private(set) var current: UInt64 = 0

    init() {}

    /// Starts a new apply and returns its generation (strictly increasing).
    @discardableResult
    mutating func advance() -> UInt64 {
        current &+= 1
        return current
    }

    /// `true` if a batch planned at `generation` predates the latest apply.
    func isStale(_ generation: UInt64) -> Bool {
        generation < current
    }
}
