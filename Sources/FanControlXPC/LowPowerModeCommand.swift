import Foundation
import Synchronization

// F2: The helper's "Low Power Mode" request (docs/helper.md "Low Power Mode request").
//
// One dedicated request, `setLowPowerMode(battery: Bool, ac: Bool)`, executed as
// `/usr/bin/pmset -a|-b|-c lowpowermode 0|1` with a FIXED argv: no shell, no string from the
// client ever reaches the command line (the only inputs are two Bools). The handler checks
// every invocation against the allowlist below, rate-limits changes, reads the per-source
// settings with `pmset -g custom` before and after, and logs each step. Platform-neutral so
// it is unit-tested with a fake runner.

/// Low Power Mode per power source, as `pmset -g custom` reports it ("Battery Power:" /
/// "AC Power:" sections). `nil` = that source has no section (no battery) or no value.
public struct LowPowerModeSettings: Codable, Hashable, Sendable {
    public var battery: Bool?
    public var ac: Bool?

    public init(battery: Bool?, ac: Bool?) {
        self.battery = battery
        self.ac = ac
    }

    /// `true` when every source that has a value equals the wanted one.
    public func matches(battery wantedBattery: Bool, ac wantedAC: Bool) -> Bool {
        (battery.map { $0 == wantedBattery } ?? true) && (ac.map { $0 == wantedAC } ?? true)
    }
}

/// The fixed `pmset` invocations of the Low Power Mode request.
public enum LowPowerModeCommand {
    /// Absolute path; never looked up through `PATH`.
    public static let pmsetPath = "/usr/bin/pmset"

    /// Which power-source flag a write uses.
    public enum Source: String, CaseIterable, Sendable {
        /// `-a`: every source (System Settings "Always" / "Never").
        case all = "-a"
        /// `-b`: battery power.
        case battery = "-b"
        /// `-c`: AC (charger) power.
        case ac = "-c"
    }

    /// `pmset -a|-b|-c lowpowermode 1|0`.
    public static func setArguments(_ source: Source = .all, enabled: Bool) -> [String] {
        [source.rawValue, "lowpowermode", enabled ? "1" : "0"]
    }

    /// `pmset -g` (current settings; readable without root). Used by the app's unprivileged
    /// diagnostics reader (`LowPowerModeReader.pmsetState`), not by the helper.
    public static let readArguments = ["-g"]

    /// `pmset -g custom` (per-source settings; readable without root). The helper's read
    /// before and after a change, and the app's capture of the user's settings.
    public static let readCustomArguments = ["-g", "custom"]

    /// The only invocations the helper may run: the six fixed writes and `-g custom`.
    public static let allowedInvocations: [[String]] =
        Source.allCases.flatMap { source in [setArguments(source, enabled: true), setArguments(source, enabled: false)] }
        + [readCustomArguments]

    /// `true` only for `pmsetPath` with exactly one of `allowedInvocations`.
    public static func isAllowed(executable: String, arguments: [String]) -> Bool {
        executable == pmsetPath && allowedInvocations.contains(arguments)
    }

    /// Per-command timeout (helper and app). Kept short so a whole request stays well
    /// inside `clientCallTimeout` (`LowPowerModeRequestHandler.worstCaseDuration`).
    public static let commandTimeout: TimeInterval = 3

    /// Reply timeout of the app's (separate, session-less) Low Power Mode connection.
    /// Larger than `LowPowerModeRequestHandler.worstCaseDuration` even with one other
    /// request queued ahead (the handler serializes requests).
    public static let clientCallTimeout: TimeInterval = 30

    /// Low Power Mode from `pmset -g` output: the `lowpowermode` line of the
    /// "Currently in use:" section (else of the whole output); `powermode` (1 = low power,
    /// on Macs that also offer High Power Mode) when there is no `lowpowermode` line.
    /// `nil` if neither is present or the value is not a number.
    public static func parseLowPowerMode(pmsetOutput output: String) -> Bool? {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        var section = lines
        if let body = sectionBody(named: "Currently in use", in: lines) {
            section = body
        }
        return lowPowerMode(in: section) ?? lowPowerMode(in: lines)
    }

    /// Per-source Low Power Mode from `pmset -g custom` output ("Battery Power:" and
    /// "AC Power:" sections; `powermode` 1 = low power where there is no `lowpowermode`
    /// line). `nil` when neither section has a value.
    public static func parseSettings(pmsetCustomOutput output: String) -> LowPowerModeSettings? {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        let battery = sectionBody(named: "Battery Power", in: lines).flatMap(lowPowerMode(in:))
        let ac = sectionBody(named: "AC Power", in: lines).flatMap(lowPowerMode(in:))
        guard battery != nil || ac != nil else { return nil }
        return LowPowerModeSettings(battery: battery, ac: ac)
    }

    /// The indented lines after the header that starts with `name` (up to the next
    /// unindented line), `nil` if there is no such header.
    private static func sectionBody(named name: String, in lines: [String]) -> [String]? {
        guard let header = lines.firstIndex(where: { line in
            line.first != " " && line.first != "\t" && line.trimmingCharacters(in: .whitespaces).hasPrefix(name)
        }) else { return nil }
        return Array(lines[(header + 1)...].prefix { $0.first == " " || $0.first == "\t" })
    }

    /// `lowpowermode` (non-zero = on), else `powermode` (1 = low power), in `lines`.
    private static func lowPowerMode(in lines: [String]) -> Bool? {
        func value(of key: String) -> Int? {
            for line in lines {
                let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                if fields.count >= 2, fields[0] == key, let number = Int(fields[1]) { return number }
            }
            return nil
        }
        if let low = value(of: "lowpowermode") { return low != 0 }
        if let mode = value(of: "powermode") { return mode == 1 }
        return nil
    }

    /// The writes that turn `current` into (`battery`, `ac`): one `-a` write when both are
    /// equal (also right on a Mac without a battery section), otherwise `-b` / `-c` for each
    /// source that differs (`-b` is skipped when `current` is known and has no battery value).
    public static func writes(battery: Bool, ac: Bool, current: LowPowerModeSettings?) -> [[String]] {
        if battery == ac {
            return [setArguments(.all, enabled: battery)]
        }
        var writes: [[String]] = []
        let hasBattery = current.map { $0.battery != nil } ?? true
        if hasBattery, current?.battery != battery { writes.append(setArguments(.battery, enabled: battery)) }
        if current?.ac != ac { writes.append(setArguments(.ac, enabled: ac)) }
        return writes
    }

    /// "on", "off", or "on battery power, off on AC power" (logs and replies).
    public static func describe(battery: Bool, ac: Bool) -> String {
        func onOff(_ value: Bool) -> String { value ? "on" : "off" }
        return battery == ac ? onOff(battery) : "\(onOff(battery)) on battery power, \(onOff(ac)) on AC power"
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
///
/// Worst case per request: `maximumCommandsPerRequest` pmset runs of at most
/// `LowPowerModeCommand.commandTimeout` each (`worstCaseDuration`, 12 s), well inside the
/// app's `LowPowerModeCommand.clientCallTimeout` (30 s) even behind one queued request.
public final class LowPowerModeRequestHandler: Sendable {
    /// At most this many changes (requests that write) per `rateWindow` (a rule loop must
    /// not hammer pmset).
    public static let defaultMaxWrites = 6
    public static let defaultRateWindow: TimeInterval = 60
    /// Per-command timeout.
    public static let commandTimeout: TimeInterval = LowPowerModeCommand.commandTimeout
    /// Read before, at most two writes (`-b`, `-c`), read-back.
    public static let maximumCommandsPerRequest = 4
    /// Upper bound of one request's duration.
    public static var worstCaseDuration: TimeInterval { Double(maximumCommandsPerRequest) * commandTimeout }

    private let runner: any CommandRunning
    private let clock: @Sendable () -> TimeInterval
    private let log: @Sendable (LowPowerModeLogLevel, String) -> Void
    private let maxWrites: Int
    private let rateWindow: TimeInterval
    /// Uptimes of recent changes (rate limit) and serialization of whole requests.
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

    /// Sets Low Power Mode for every power source (`-a`).
    public func handle(enabled: Bool, requester: String) -> (code: FanControlHelperErrorCode, message: String) {
        handle(battery: enabled, ac: enabled, requester: requester)
    }

    /// Sets Low Power Mode on battery and on AC power. `requester` (e.g. "pid 123") is used
    /// for logging only. Replies `.ok` when the read-back matches (or the settings already
    /// matched: no write), `.rateLimited` past the change budget, `.commandFailed` when
    /// pmset fails or the read-back disagrees.
    public func handle(battery: Bool, ac: Bool, requester: String) -> (code: FanControlHelperErrorCode, message: String) {
        requestLock.withLock { _ in
            let wanted = LowPowerModeCommand.describe(battery: battery, ac: ac)
            log(.notice, "\(requester) requests Low Power Mode \(wanted)")

            let before = readSettings()
            if let before, before.matches(battery: battery, ac: ac) {
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

            for arguments in LowPowerModeCommand.writes(battery: battery, ac: ac, current: before) {
                guard let result = runAllowed(arguments) else {
                    return (.commandFailed, "The Low Power Mode command is not allowed.")
                }
                guard result.status == 0 else {
                    let detail = Self.trimmed(result.standardError.isEmpty ? result.standardOutput : result.standardError)
                    log(.error, "pmset \(arguments.joined(separator: " ")) failed with status \(result.status): \(detail)")
                    return (.commandFailed, "pmset failed (status \(result.status))\(detail.isEmpty ? "" : ": \(detail)")")
                }
            }

            guard let after = readSettings() else {
                log(.notice, "Low Power Mode set \(wanted); read-back unavailable")
                return (.ok, "Low Power Mode \(wanted) (not confirmed).")
            }
            guard after.matches(battery: battery, ac: ac) else {
                let seen = LowPowerModeCommand.describe(battery: after.battery ?? after.ac ?? false,
                                                        ac: after.ac ?? after.battery ?? false)
                log(.error, "pmset succeeded but Low Power Mode reads back \(seen)")
                return (.commandFailed, "Low Power Mode did not change (read back \(seen)).")
            }
            log(.notice, "Low Power Mode is now \(wanted) (read back)")
            return (.ok, "Low Power Mode \(wanted).")
        }
    }

    /// `pmset -g custom` → per-source settings, `nil` if unreadable.
    private func readSettings() -> LowPowerModeSettings? {
        guard let result = runAllowed(LowPowerModeCommand.readCustomArguments), result.status == 0 else { return nil }
        return LowPowerModeCommand.parseSettings(pmsetCustomOutput: result.standardOutput)
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
