#if os(macOS)
import Foundation
import FanControlXPC

// FanControlHelper: privileged launchd daemon registered by DynamicNotch through
// `SMAppService.daemon(plistName:)`. launchd starts it on demand when DynamicNotch
// connects to the Mach service; it then serves `FanControlHelperProtocol`.

let listenerDelegate = HelperListenerDelegate()  // NSXPCListener.delegate is weak: keep a strong ref.
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

helperLog.info("FanControlHelper started (protocol v\(FanControlHelperConstants.protocolVersion, privacy: .public), build \(HelperConfiguration.buildString, privacy: .public)), listening on \(FanControlHelperConstants.machServiceName, privacy: .public)")
dispatchMain()
#else
print("FanControlHelper is macOS-only")
#endif
