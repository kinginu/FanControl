#if os(macOS)
import Foundation
import FanControlCore
import FanControlXPC

/// Exit statuses of FanControlHelper (sysexits(3) values). `launchctl print system/<label>`
/// shows the last one as `last exit code`. launchd starts the helper again on the next
/// connection to its Mach service (throttled), whatever the status.
enum HelperExitStatus: Int32, Sendable {
    /// `--print-configuration` / `--help` printed; or SIGTERM / SIGINT handled with every fan
    /// handed back to the SMC (or no session open).
    case success = 0
    /// Unknown command-line argument (launchd passes none).
    case usage = 64  // EX_USAGE
    /// SIGTERM / SIGINT handled, but at least one restore write failed; a fan may still be
    /// forced (fault log "restore FAILED"). Recover with "Return to automatic" in the app,
    /// a reboot, or an SMC reset.
    case restoreFailed = 74  // EX_IOERR
    /// Refused to start, without listening: not Apple silicon, or an invalid
    /// `FANCONTROL_CLIENT_REQUIREMENT` (manual install). The client sees an invalidated
    /// connection.
    case configuration = 78  // EX_CONFIG

    func exitProcess() -> Never {
        exit(rawValue)
    }
}

/// What the command line asks for.
enum HelperCommand: Equatable, Sendable {
    /// No arguments (how launchd starts the daemon): serve the Mach service.
    case serve
    /// `--print-configuration`: print the resolved identifiers as JSON and exit. No SMC
    /// access, no listener; used to check a build.
    case printConfiguration
    /// `--help` / `-h`.
    case help
    /// Anything else.
    case unknown(String)

    init(arguments: some Collection<String>) {
        if arguments.contains("--print-configuration") {
            self = .printConfiguration
        } else if arguments.contains(where: { $0 == "--help" || $0 == "-h" }) {
            self = .help
        } else if let first = arguments.first {
            self = .unknown(first)
        } else {
            self = .serve
        }
    }

    static let usage = """
        usage: FanControlHelper                         run as the launchd daemon (no arguments)
               FanControlHelper --print-configuration   print the resolved identifiers as JSON and exit
        """
}

/// Process bootstrap of the privileged helper (`main.swift` only calls `run`).
///
/// Order in `serve()`: refuse unsupported hardware and invalid configuration (exit 78
/// before listening) → install the SIGTERM / SIGINT handlers → register for sleep/wake →
/// resume the XPC listener last, so no session can open before every way of restoring it
/// is in place → `dispatchMain()`.
enum HelperDaemon {
    static func run(arguments: [String]) -> Never {
        switch HelperCommand(arguments: arguments.dropFirst()) {
        case .serve:
            serve()
        case .printConfiguration:
            print(HelperConfiguration.configurationJSON())
            HelperExitStatus.success.exitProcess()
        case .help:
            print(HelperCommand.usage)
            HelperExitStatus.success.exitProcess()
        case .unknown(let argument):
            FileHandle.standardError.write(Data("FanControlHelper: unknown argument '\(argument)'\n\(HelperCommand.usage)\n".utf8))
            HelperExitStatus.usage.exitProcess()
        }
    }

    private static func serve() -> Never {
        // Apple Silicon only (Intel dropped 2026-10-20): refuse to serve on other hardware
        // rather than write an untested scheme.
        guard FanControlHost.isAppleSilicon else {
            helperLog.fault("Startup: Refusing to start: \(FanControlHost.unsupportedDetail, privacy: .public)")
            HelperExitStatus.configuration.exitProcess()
        }

        HelperConfiguration.logIdentifiers()

        // Client requirement: Team ID (SMAppService) or the cdhash-pinned override from the
        // manual-install LaunchDaemon plist. An invalid override must never fall back to
        // something weaker: refuse to listen and exit.
        let clientRequirement: ClientRequirement
        switch HelperConfiguration.resolveClientRequirement() {
        case .success(let resolved):
            clientRequirement = resolved
        case .failure(let error):
            helperLog.fault("Startup: Refusing to start: invalid \(FanControlHelperConstants.clientRequirementEnvironmentKey, privacy: .public): \(error.description, privacy: .public)")
            HelperExitStatus.configuration.exitProcess()
        }
        HelperConfiguration.logClientRequirement(clientRequirement)

        let signalSources = installTerminationHandlers()

        // Sleep/wake: hand forced fans back to the SMC before sleep and re-apply the
        // session's targets after wake (the SMC resets F<n>Tg to 0 but keeps F<n>Md = 1).
        PowerObserver.shared.start()

        let listenerDelegate = HelperListenerDelegate(clientRequirement: clientRequirement.requirement)
        let listener = NSXPCListener(machServiceName: FanControlHelperConstants.machServiceName)
        listener.delegate = listenerDelegate  // weak: kept alive below
        listener.resume()

        helperLog.notice("Startup: FanControlHelper started (protocol v\(FanControlHelperConstants.protocolVersion, privacy: .public), build \(HelperConfiguration.buildString, privacy: .public)), listening on \(FanControlHelperConstants.machServiceName, privacy: .public)")
        // `dispatchMain()` never returns; without this the optimiser may release the
        // listener, its (weak) delegate and the signal sources before it is called.
        withExtendedLifetime((listener, listenerDelegate, signalSources)) {
            dispatchMain()
        }
    }

    /// SIGTERM (launchd: unregister, `launchctl kill`, shutdown) and SIGINT (a terminal):
    /// restore the fans, then exit. The default actions are ignored so that only the
    /// dispatch sources see the signals. SIGKILL cannot be handled (docs/helper.md).
    private static func installTerminationHandlers() -> [any DispatchSourceSignal] {
        [(SIGTERM, "SIGTERM"), (SIGINT, "SIGINT")].map { signalNumber, name in
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { terminate(signalName: name) }
            source.resume()
            return source
        }
    }

    private static func terminate(signalName: String) -> Never {
        helperLog.notice("Shutdown: \(signalName, privacy: .public) received")
        let report = SessionRegistry.shared.shutdown()
        let status: HelperExitStatus = report.succeeded ? .success : .restoreFailed
        helperLog.notice("Shutdown: exiting with status \(status.rawValue, privacy: .public)")
        status.exitProcess()
    }
}
#endif
