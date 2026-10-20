#if os(macOS)
import Foundation
import FanControlCore

/// Records the error of a user-facing operation into the facade's `lastError`
/// and rethrows it (docs/kit.md "Architecture"). The components that run
/// user actions (`FanController`, `HelperCoordinator`) wrap their public-facing
/// methods in it; `FanControlManager` installs the closure at init.
struct ErrorRecorder {
    /// Receives the error mapped by `FanControlPoller.fanControlError(from:)`.
    var record: @MainActor (FanControlError) -> Void

    /// Drops every error (the default until the facade wires itself in).
    static var ignoring: ErrorRecorder { ErrorRecorder { _ in } }

    /// Runs `body`; on failure records the error and rethrows it.
    @MainActor
    func callAsFunction(_ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch {
            record(FanControlPoller.fanControlError(from: error))
            throw error
        }
    }
}
#endif
