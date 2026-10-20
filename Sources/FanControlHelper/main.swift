#if os(macOS)
import Foundation
import FanControlXPC

// FanControlHelper: privileged launchd daemon registered by DynamicNotch through
// `SMAppService.daemon(plistName:)`, or installed by `Support/manual-install/install.sh`
// as a plain LaunchDaemon (manual / personal mode). launchd starts it on demand when DynamicNotch
// connects to the Mach service; it then serves `FanControlHelperProtocol`.

// Client requirement: Team ID (SMAppService) or the cdhash-pinned override from the
// manual-install LaunchDaemon plist. An invalid override must never fall back to
// something weaker: refuse to listen and exit (launchd retries on the next connect,
// throttled; the client sees an invalidated connection).
let clientRequirement: ClientRequirement
switch HelperConfiguration.resolveClientRequirement() {
case .success(let resolved):
    clientRequirement = resolved
case .failure(let error):
    helperLog.fault("Refusing to start: invalid \(FanControlHelperConstants.clientRequirementEnvironmentKey, privacy: .public): \(error.description, privacy: .public)")
    exit(78)  // EX_CONFIG
}
switch clientRequirement.mode {
case .teamID:
    helperLog.notice("Client requirement mode: Team ID (SMAppService) - \(clientRequirement.requirement, privacy: .public)")
case .manualCDHash(let hash):
    helperLog.notice("Client requirement mode: MANUAL INSTALL (personal use), client cdhash pinned to \(hash, privacy: .public) - \(clientRequirement.requirement, privacy: .public)")
}

let listenerDelegate = HelperListenerDelegate(clientRequirement: clientRequirement.requirement)  // NSXPCListener.delegate is weak: keep a strong ref.
let listener = NSXPCListener(machServiceName: FanControlHelperConstants.machServiceName)
listener.delegate = listenerDelegate
listener.resume()

// launchd sends SIGTERM on unregister / shutdown: restore fans to automatic before exiting.
// The default action is ignored so only the dispatch source sees the signal.
signal(SIGTERM, SIG_IGN)
let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)  // strong global ref
sigtermSource.setEventHandler {
    helperLog.notice("SIGTERM received")
    SessionRegistry.shared.shutdown()
    exit(0)
}
sigtermSource.resume()

// Sleep/wake: hand forced fans back to the SMC before sleep and re-apply the
// session's targets after wake (the SMC resets F<n>Tg to 0 but keeps F<n>Md = 1).
PowerObserver.shared.start()

helperLog.info("FanControlHelper started (protocol v\(FanControlHelperConstants.protocolVersion, privacy: .public), build \(HelperConfiguration.buildString, privacy: .public)), listening on \(FanControlHelperConstants.machServiceName, privacy: .public)")
dispatchMain()
#else
print("FanControlHelper is macOS-only")
#endif
