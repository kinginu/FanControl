// fanfi-probe — read-only SMC probe for Phase 1 verification (docs/integration.md §6).
//
// READ-ONLY BY DESIGN. This tool must never write to the SMC: it uses only
// `SMCReader` methods (keyInfo / readBytes / keyCount / key(at:)) and the
// read-only `SMCClient.dump()`. Do not call `SMCClient.writeBytes`, anything on
// `SMCWriter`, profile application or helper registration from here, and do
// not add any write option. It runs unprivileged (no sudo needed).
//
// Layout: ProbeOptions.swift (command line, help, exit codes) → ProbeSession.swift
// (all SMC reads) → TextRenderer.swift / JSONRenderer.swift (pure rendering);
// FanStatsRunner.swift samples for `--fan-stats`. `fanfi-probe --help` lists the CLI.

#if os(macOS)
import Foundation
import FanControlCore
import FanControlSMC

/// Unbuffered output: each block is written in one call, so `--watch` stays live
/// when stdout is a pipe or file.
func emit(_ lines: [String]) {
    guard !lines.isEmpty else { return }
    FileHandle.standardOutput.write(Data((lines.joined(separator: "\n") + "\n").utf8))
}

func emitError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func finish(_ code: ProbeExitCode) -> Never { exit(code.rawValue) }

let options: ProbeOptions
do {
    options = try ProbeCommandLine.parse(CommandLine.arguments.dropFirst())
} catch {
    emitError("fanfi-probe: \(error)")
    emitError(ProbeCommandLine.usageLine)
    emitError("Try 'fanfi-probe --help' for more information.")
    finish(.usage)
}

if options.command == .help {
    emit([ProbeCommandLine.helpText])
    finish(.success)
}

// Apple Silicon only (Intel dropped 2026-10-20). Reading is harmless, so the
// probe still runs, but its labels and aggregates assume Apple Silicon.
let host = HostInfo.current()
if !host.isAppleSilicon {
    emitError("warning: unsupported host: \(FanControlHost.unsupportedDetail)")
}

let session: ProbeSession
do {
    session = try ProbeSession()
} catch {
    emitError("SMC connection failed: \(error) (AppleSMC available: \(SMCConnection.isAvailable()))")
    finish(.smcUnavailable)
}

/// Machine header, raw fan keys and discovery summary (text snapshot and text `--fan-stats`).
/// Top-level globals such as `session` are main-actor isolated in Swift 6.
@MainActor
func emitPreamble() {
    emit(TextRenderer.preamble(host: host, keyCount: session.keyCount(), fanDiscoveryError: session.fanDiscoveryError,
                               rawFanKeys: session.rawFanKeys(), temperatureKeyCount: session.sensorKeys.count))
}

switch options.command {
case .help:
    break // handled above

case .dump:
    emit([session.dump()])
    finish(.success)

case .fanStats(let seconds):
    let interval = options.watchInterval ?? ProbeOptions.defaultFanStatsInterval
    let started = Date()
    if !options.json {
        emitPreamble()
        emit(TextRenderer.fanStatsHeader(seconds: seconds, interval: interval, criteria: .default))
    }
    let result = FanStatsRunner.run(session: session, seconds: seconds, interval: interval) { elapsed, current, target in
        if !options.json {
            emit([TextRenderer.fanStatsSample(elapsed: elapsed, fans: session.fans, current: current, target: target)])
        }
    }
    if options.json {
        emit([JSONRenderer.encode(JSONRenderer.fanStats(result, date: started), pretty: true)])
    } else {
        emit(TextRenderer.fanStatsReport(result))
    }
    finish(result.passed ? .success : .fanStatsFailed)

case .snapshot:
    let errors = [session.fanDiscoveryError.map { "fan discovery failed: \($0)" },
                  session.sensorDiscoveryError.map { "temperature discovery failed: \($0)" }].compactMap { $0 }
    if options.json {
        let keyCount = session.keyCount()
        // One pretty document, or JSON Lines (one compact object per readout) with --watch.
        let pretty = options.watchInterval == nil
        func emitSnapshot() {
            let document = JSONRenderer.snapshot(session.snapshot(), host: host, keyCount: keyCount, errors: errors)
            emit([JSONRenderer.encode(document, pretty: pretty)])
        }
        emitSnapshot()
        if let interval = options.watchInterval {
            while true {
                Thread.sleep(forTimeInterval: interval)
                emitSnapshot()
            }
        }
    } else {
        emitPreamble()
        emit(TextRenderer.readout(session.snapshot()))
        if let interval = options.watchInterval {
            while true {
                Thread.sleep(forTimeInterval: interval)
                emit([""] + TextRenderer.readout(session.snapshot()))
            }
        }
    }
    finish(.success)
}
#else
print("fanfi-probe requires macOS")
#endif
