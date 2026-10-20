import Foundation
import Synchronization

// F2: The helper's "Low Power Mode" request (docs/helper.md "Low Power Mode request").
//
// One dedicated request, `setLowPowerMode(_ enabled: Bool)`, executed as
// `/usr/bin/pmset -a lowpowermode 0|1` with a FIXED argv: no shell, no string from the
// client ever reaches the command line (the only input is a Bool). The handler checks every
// invocation against the allowlist below, rate-limits writes, reads the state back with
// `pmset -g` and logs each step. Platform-neutral so it is unit-tested with a fake runner.

/// The fixed `pmset` invocations of the Low Power Mode request.
public enum LowPowerModeCommand {
    /// Absolute path; never looked up through `PATH`.
    public static let pmsetPath = "/usr/bin/pmset"

    /// `pmset -a lowpowermode 1|0` (all power sources, like System Settings' "Always" / "Never").
    public static func setArguments(enabled: Bool) -> [String] {
        ["-a", "lowpowermode", enabled ? "1" : "0"]
    }

    /// `pmset -g` (current settings; readable without root, used for the read-back).
    public static let readArguments = ["-g"]

    /// The only three invocations the helper may run.
    public static let allowedInvocations: [[String]] = [
        setArguments(enabled: true), setArguments(enabled: false), readArguments,
    ]

    /// `true` only for `pmsetPath` with exactly one of `allowedInvocations`.
    public static func isAllowed(executable: String, arguments: [String]) -> Bool {
        executable == pmsetPath && allowedInvocations.contains(arguments)
    }

    /// Low Power Mode from `pmset -g` output: the `lowpowermode` line of the
    /// "Currently in use:" section (else of the whole output); `powermode` (1 = low power,
    /// on Macs that also offer High Power Mode) when there is no `lowpowermode` line.
    /// `nil` if neither is present or the value is not a number.
    public static func parseLowPowerMode(pmsetOutput output: String) -> Bool? {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        var section = lines
        if let header = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Currently in use") }) {
            // The section ends at the next unindented line (another header).
            let body = lines[(header + 1)...].prefix { $0.first == " " || $0.first == "\t" }
            section = Array(body)
        }
        func value(of key: String, in lines: [String]) -> Int? {
            for line in lines {
                let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                if fields.count >= 2, fields[0] == key, let number = Int(fields[1]) { return number }
            }
            return nil
        }
        if let low = value(of: "lowpowermode", in: section) ?? value(of: "lowpowermode", in: lines) {
            return low != 0
        }
        if let mode = value(of: "powermode", in: section) ?? value(of: "powermode", in: lines) {
            return mode == 1
        }
        return nil
    }
}

/// Result of one external command.
public struct CommandResult: Hashable, Sendable {
    /// Exit status; `-1` when the command could not be started or timed out.
    public var status: Int32
    public var standardOutput: String
    public var standardError: String

    public init(status: Int32, standardOutput: String = "", standardError: String = "") {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

/// Runs an executable with an argv array (no shell). The helper uses `Process`; tests a fake.
public protocol CommandRunning: Sendable {
    func run(executable: String, arguments: [String], timeout: TimeInterval) -> CommandResult
}

/// Runs an executable directly (`Process`, no shell) with an empty environment
/// (plus a fixed `PATH`), and kills it after `timeout`.
public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(executable: String, arguments: [String], timeout: TimeInterval) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, standardError: "could not start \(executable): \(error.localizedDescription)")
        }
        // pmset writes far less than the pipe buffer (64 KiB), so it never blocks on output:
        // wait for the exit first, then read both pipes to EOF.
        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return CommandResult(status: -1, standardError: "timed out after \(Int(timeout)) s")
        }
        let stdoutData = output.fileHandleForReading.readDataToEndOfFile()
        let stderrData = errors.fileHandleForReading.readDataToEndOfFile()
        return CommandResult(status: process.terminationStatus,
                             standardOutput: String(decoding: stdoutData, as: UTF8.self),
                             standardError: String(decoding: stderrData, as: UTF8.self))
    }
}

/// Log levels of `LowPowerModeRequestHandler` (mapped to `os.Logger` by the helper).
public enum LowPowerModeLogLevel: Sendable {
    case info, notice, error
}

/// Executes the Low Power Mode request (helper side). Thread-safe.
public final class LowPowerModeRequestHandler: Sendable {
    /// At most this many `pmset` writes per `rateWindow` (a rule loop must not hammer pmset).
    public static let defaultMaxWrites = 6
    public static let defaultRateWindow: TimeInterval = 60
    /// Per-command timeout.
    public static let commandTimeout: TimeInterval = 10

    private let runner: any CommandRunning
    private let clock: @Sendable () -> TimeInterval
    private let log: @Sendable (LowPowerModeLogLevel, String) -> Void
    private let maxWrites: Int
    private let rateWindow: TimeInterval
    /// Uptimes of recent writes (rate limit) and serialization of whole requests.
    private let recentWrites = Mutex<[TimeInterval]>([])
    private let requestLock = Mutex<Void>(())

    public init(runner: any CommandRunning,
                clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                maxWrites: Int = LowPowerModeRequestHandler.defaultMaxWrites,
                rateWindow: TimeInterval = LowPowerModeRequestHandler.defaultRateWindow,
                log: @escaping @Sendable (LowPowerModeLogLevel, String) -> Void = { _, _ in }) {
        self.runner = runner
        self.clock = clock
        self.maxWrites = maxWrites
        self.rateWindow = rateWindow
        self.log = log
    }

    /// Sets Low Power Mode. `requester` (e.g. "pid 123") is used for logging only.
    /// Replies `.ok` when the read-back matches (or the state already matched: no write),
    /// `.rateLimited` past the write budget, `.commandFailed` when pmset fails or the
    /// read-back disagrees.
    public func handle(enabled: Bool, requester: String) -> (code: FanControlHelperErrorCode, message: String) {
        requestLock.withLock { _ in
            let wanted = enabled ? "on" : "off"
            log(.notice, "\(requester) requests Low Power Mode \(wanted)")

            if readState() == enabled {
                log(.info, "Low Power Mode already \(wanted); nothing written")
                return (.ok, "Low Power Mode is already \(wanted).")
            }

            let now = clock()
            let admitted: Bool = recentWrites.withLock { writes in
                writes.removeAll { now - $0 >= rateWindow }
                guard writes.count < maxWrites else { return false }
                writes.append(now)
                return true
            }
            guard admitted else {
                log(.error, "Low Power Mode request refused: more than \(maxWrites) changes within \(Int(rateWindow)) s")
                return (.rateLimited, "Too many Low Power Mode changes; try again in a minute.")
            }

            let arguments = LowPowerModeCommand.setArguments(enabled: enabled)
            guard let result = runAllowed(arguments) else {
                return (.commandFailed, "The Low Power Mode command is not allowed.")
            }
            guard result.status == 0 else {
                let detail = Self.trimmed(result.standardError.isEmpty ? result.standardOutput : result.standardError)
                log(.error, "pmset \(arguments.joined(separator: " ")) failed with status \(result.status): \(detail)")
                return (.commandFailed, "pmset failed (status \(result.status))\(detail.isEmpty ? "" : ": \(detail)")")
            }

            switch readState() {
            case .some(enabled):
                log(.notice, "Low Power Mode is now \(wanted) (read back)")
                return (.ok, "Low Power Mode \(wanted).")
            case .some:
                log(.error, "pmset succeeded but Low Power Mode reads back \(enabled ? "off" : "on")")
                return (.commandFailed, "Low Power Mode did not change (read back \(enabled ? "off" : "on")).")
            case .none:
                log(.notice, "Low Power Mode set \(wanted); read-back unavailable")
                return (.ok, "Low Power Mode \(wanted) (not confirmed).")
            }
        }
    }

    /// `pmset -g` → state, `nil` if unreadable.
    private func readState() -> Bool? {
        guard let result = runAllowed(LowPowerModeCommand.readArguments), result.status == 0 else { return nil }
        return LowPowerModeCommand.parseLowPowerMode(pmsetOutput: result.standardOutput)
    }

    /// Runs an allowlisted invocation; `nil` (and a log line) for anything else.
    private func runAllowed(_ arguments: [String]) -> CommandResult? {
        guard LowPowerModeCommand.isAllowed(executable: LowPowerModeCommand.pmsetPath, arguments: arguments) else {
            log(.error, "Refusing to run non-allowlisted pmset arguments \(arguments)")
            return nil
        }
        return runner.run(executable: LowPowerModeCommand.pmsetPath, arguments: arguments,
                          timeout: Self.commandTimeout)
    }

    /// First line, at most 200 characters (for replies and logs).
    static func trimmed(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return String(line.trimmingCharacters(in: .whitespaces).prefix(200))
    }
}
