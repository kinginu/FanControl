// Command-line surface of fanfi-probe: options, parsing, help text and exit codes.
// Pure (no SMC access, no output), so the rules here are easy to reason about.

#if os(macOS)
import Foundation

/// Process exit status. Scripts may rely on these values (docs/integration.md §6).
enum ProbeExitCode: Int32 {
    /// The readout / dump completed, or every fan passed `--fan-stats`.
    case success = 0
    /// `--fan-stats` verdict: at least one fan FAILed (or no fans were found).
    case fanStatsFailed = 1
    /// Invalid command line.
    case usage = 2
    /// The AppleSMC user client could not be opened (nothing was read).
    case smcUnavailable = 3
}

/// What the probe was asked to do.
struct ProbeOptions: Equatable {
    enum Command: Equatable {
        /// Machine, raw fan keys, fans, temperatures and aggregates (default).
        case snapshot
        /// Every SMC key with type / size / attributes / raw bytes (`--dump`).
        case dump
        /// Hunting test over a window of `seconds` (`--fan-stats N`).
        case fanStats(seconds: Double)
        /// Print the help text (`-h`, `--help`).
        case help
    }

    var command: Command = .snapshot
    /// `--watch N`: repeat the snapshot every N seconds; with `--fan-stats`, the sample interval.
    var watchInterval: Double?
    /// `--json`: machine-readable output instead of the text tables.
    var json = false

    /// Sample interval for `--fan-stats` when `--watch` is not given.
    static let defaultFanStatsInterval: Double = 1
}

/// A command-line error; printed with the short usage line, exit status 2.
struct ProbeUsageError: Error, CustomStringConvertible, Equatable {
    let description: String
}

enum ProbeCommandLine {
    static let usageLine = "usage: fanfi-probe [--dump | --fan-stats N] [--watch N] [--json] [--help]"

    static let helpText = """
    fanfi-probe — read-only SMC probe (fans, temperatures, aggregates). Never writes; no sudo.

    \(usageLine)

    Modes:
      (default)        machine model, SMC key count, raw fan keys, fans, temperature
                       sensors and aggregated sensors (agg:cpu, agg:gpu, …)
      --dump           every SMC key with type/size/attributes and raw bytes, then exit
      --fan-stats N    hunting test: sample every fan's actual/target RPM for N seconds,
                       print per-fan statistics and a PASS/FAIL verdict, then exit

    Options:
      --watch N        repeat the fan/temperature readout every N seconds (Ctrl-C to stop);
                       with --fan-stats, the sample interval (default 1)
      --json           machine-readable output: one pretty-printed JSON object; with --watch,
                       one compact object per line (JSON Lines); with --fan-stats, the report
      -h, --help       show this help

    Values may also be given as --watch=N / --fan-stats=N. N is a positive number of seconds.
    --dump cannot be combined with --watch, --fan-stats or --json.

    Exit status:
      0  success (for --fan-stats: every fan PASS)
      1  --fan-stats: at least one fan FAIL, or no fans found
      2  invalid command line
      3  the SMC could not be opened
    """

    /// Parses `arguments` (without the program name). `-h` / `--help` anywhere wins.
    static func parse<S: Sequence>(_ arguments: S) throws -> ProbeOptions where S.Element == String {
        var options = ProbeOptions()
        var wantDump = false
        var fanStatsSeconds: Double?
        var remaining = Array(arguments)[...]

        while let raw = remaining.popFirst() {
            // Accept `--flag=value` as well as `--flag value`.
            let (flag, inlineValue): (String, String?) = {
                guard raw.hasPrefix("--"), let eq = raw.firstIndex(of: "=") else { return (raw, nil) }
                return (String(raw[..<eq]), String(raw[raw.index(after: eq)...]))
            }()
            func seconds() throws -> Double {
                guard let value = inlineValue ?? remaining.popFirst() else {
                    throw ProbeUsageError(description: "\(flag) requires a value (seconds)")
                }
                guard let number = Double(value), number.isFinite, number > 0 else {
                    throw ProbeUsageError(description: "\(flag): expected a positive number of seconds, got '\(value)'")
                }
                return number
            }
            func noValue() throws {
                if let inlineValue {
                    throw ProbeUsageError(description: "\(flag) takes no value (got '\(inlineValue)')")
                }
            }

            switch flag {
            case "-h", "--help":
                return ProbeOptions(command: .help)
            case "--dump":
                try noValue()
                wantDump = true
            case "--json":
                try noValue()
                options.json = true
            case "--watch":
                options.watchInterval = try seconds()
            case "--fan-stats":
                fanStatsSeconds = try seconds()
            default:
                if flag.hasPrefix("-") {
                    throw ProbeUsageError(description: "unknown option '\(flag)'")
                }
                throw ProbeUsageError(description: "unexpected argument '\(raw)'")
            }
        }

        if wantDump {
            var conflicts: [String] = []
            if fanStatsSeconds != nil { conflicts.append("--fan-stats") }
            if options.watchInterval != nil { conflicts.append("--watch") }
            if options.json { conflicts.append("--json") }
            if !conflicts.isEmpty {
                throw ProbeUsageError(description: "--dump cannot be combined with \(conflicts.joined(separator: ", "))")
            }
            options.command = .dump
        } else if let fanStatsSeconds {
            options.command = .fanStats(seconds: fanStatsSeconds)
        }
        return options
    }
}
#endif
