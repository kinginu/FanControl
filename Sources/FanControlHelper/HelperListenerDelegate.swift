#if os(macOS)
import Foundation
import FanControlXPC

/// Accepts XPC connections from DynamicNotch only (code-signing requirement enforced by the system).
final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let connectionCounterLock = NSLock()
    private var nextConnectionID: UInt64 = 1
    /// `HelperConfiguration.resolveClientRequirement()` result: the Team-ID requirement,
    /// or the cdhash-pinned `FANCONTROL_CLIENT_REQUIREMENT` override (manual install).
    private let clientRequirement: String

    init(clientRequirement: String) {
        self.clientRequirement = clientRequirement
        super.init()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // macOS 13+: messages from a client that does not satisfy the requirement are
        // rejected and the connection is invalidated by the system.
        newConnection.setCodeSigningRequirement(clientRequirement)

        let owner = SessionOwner(pid: newConnection.processIdentifier, connectionID: makeConnectionID())
        newConnection.exportedInterface = makeHelperInterface()
        newConnection.exportedObject = HelperService(owner: owner)
        newConnection.invalidationHandler = {
            helperLog.info("Connection \(owner.connectionID, privacy: .public) from pid \(owner.pid, privacy: .public) invalidated")
            SessionRegistry.shared.release(owner: owner)
        }
        newConnection.interruptionHandler = {
            helperLog.info("Connection \(owner.connectionID, privacy: .public) from pid \(owner.pid, privacy: .public) interrupted")
            SessionRegistry.shared.release(owner: owner)
        }
        newConnection.resume()
        helperLog.info("Accepted connection \(owner.connectionID, privacy: .public) from pid \(owner.pid, privacy: .public)")
        return true
    }

    private func makeConnectionID() -> UInt64 {
        connectionCounterLock.lock()
        defer { connectionCounterLock.unlock() }
        let id = nextConnectionID
        nextConnectionID += 1
        return id
    }
}
#endif
