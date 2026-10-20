#if os(macOS)
import Foundation
import Synchronization
import FanControlXPC

/// Accepts XPC connections that satisfy the client code-signing requirement (enforced by
/// the system) and gives each one its own `HelperService` and `SessionOwner` identity.
///
/// `Sendable` without locks around mutable state: the requirement is immutable and the
/// connection counter is an `Atomic`, so `listener(_:shouldAcceptNewConnection:)` may run
/// on any XPC queue.
final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate, Sendable {
    /// `HelperConfiguration.resolveClientRequirement()` result: the Team-ID requirement,
    /// or the cdhash-pinned `FANCONTROL_CLIENT_REQUIREMENT` override (manual install).
    private let clientRequirement: String
    /// Next `SessionOwner.connectionID` (starts at 1; never reused within a process).
    private let nextConnectionID = Atomic<UInt64>(1)

    init(clientRequirement: String) {
        self.clientRequirement = clientRequirement
        super.init()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // macOS 13+: messages from a client that does not satisfy the requirement are
        // rejected and the connection is invalidated by the system.
        newConnection.setCodeSigningRequirement(clientRequirement)

        let owner = SessionOwner(pid: newConnection.processIdentifier,
                                 connectionID: nextConnectionID.wrappingAdd(1, ordering: .relaxed).oldValue)
        newConnection.exportedInterface = makeHelperInterface()
        newConnection.exportedObject = HelperService(owner: owner)
        // Both end the connection's session (if it holds one) with the full restore. A
        // listener-side connection is normally only invalidated, never interrupted.
        newConnection.invalidationHandler = {
            helperLog.info("XPC: connection \(owner.connectionID, privacy: .public) from pid \(owner.pid, privacy: .public) invalidated")
            SessionRegistry.shared.release(owner: owner)
        }
        newConnection.interruptionHandler = {
            helperLog.info("XPC: connection \(owner.connectionID, privacy: .public) from pid \(owner.pid, privacy: .public) interrupted")
            SessionRegistry.shared.release(owner: owner)
        }
        newConnection.resume()
        helperLog.info("XPC: Accepted connection \(owner.connectionID, privacy: .public) from pid \(owner.pid, privacy: .public)")
        return true
    }
}
#endif
