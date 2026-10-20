# Changelog

All notable changes to this package are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/). The XPC contract between the app and the helper has
its own number, `FanControlHelperConstants.protocolVersion`, which is listed with each release.

## [1.0.0] — 2026-10-21

First release. Helper XPC protocol **version 2**.

### Platform

- **Apple Silicon only.** On a Mac that is not arm64 the kit refuses to open the SMC
  (`FanControlError.unsupportedPlatform`) and the helper exits at launch with code 78. The Intel
  code paths (`FS!` force bits, Intel write strategies and sensor tables) were removed before
  this release.
- Deployment target **macOS 26**, Swift 6.0+ tools, Swift 6 language mode with complete strict
  concurrency in every target.
- Verified on hardware: MacBook Pro 14" **Mac14,9** (M2 Pro, two fans, 2317–6800 RPM) with
  macOS 26.5. No other model has been tested ([docs/verification/SUMMARY.md](docs/verification/SUMMARY.md)).

### Products

- `FanControlCore` — pure logic with no I/O: SMC key, type and codec handling (`flt`, `ioft`
  little-endian, `si64`, read bit `0x80` / write bit `0x40`), fan discovery, the control engine,
  multi-point **PCHIP fan curves**, temperature smoothing and the target stabiliser (deadband,
  dwell, slew), `TemperatureSampleFilter` for implausible Apple Silicon readings, aggregate
  sensors (`agg:cpu`, `agg:cpu.p`, `agg:cpu.e`, `agg:gpu`), profiles and presets, safety
  thresholds (warning 90 °C / forced maximum 95 °C / hysteresis 5 °C, provisional) and the
  power-aware polling policy.
- `FanControlSMC` — an unprivileged IOKit `AppleSMC` client (enumeration, key info, reads) and
  the raw write path used by the helper.
- `FanControlXPC` — the helper protocol and constants, the write allowlist and value validation
  (`HelperWritePolicy`), the sleep/wake policy (`PowerTransitionPolicy`) and the manual-install
  code-signing requirement builders.
- `FanControlKit` — the app-side `@MainActor @Observable` `FanControlManager` facade with its
  monitoring, controller, helper, wake and error components; the polling actor; the helper
  client and connection gate; the `SMAppService` installer; power-source monitoring; detection
  of other fan-control apps; the profile arbiter (manual pick, power rules, workload rules);
  charge limit and Low Power Mode requests.
- `FanControlUI` — SwiftUI settings pane, curve editor, temperature chart and stored settings.
- `FanControlHelper` — the privileged launchd daemon (ship it as an Xcode Command Line Tool
  target, see [docs/integration.md](docs/integration.md)).
- `fanfi-probe` — a read-only diagnostic CLI (fans, temperatures, aggregates, full key dumps,
  hunting check, JSON output). It never writes and needs no `sudo`.

### Helper and safety

- Only `F<n>Md` and `F<n>Tg` are writable, only for existing fans, only on keys with the SMC
  write bit, and only with targets inside `Mn…Mx`. Writes go `Md` before `Tg`; a partial
  failure is rolled back.
- Restore hands the fans back to the SMC with `Md = 0` only (verified on hardware: no `Tg`
  write-back is needed). The helper restores on client disconnect (including `kill -9`), on
  SIGTERM and before sleep, and re-applies the session at 0 / 1 / 3 s after wake. The app also
  re-applies on wake and repairs drifted fans on every poll (`UnsettledFanDetector`).
- Emergency override forces every fan to its maximum above the threshold, including fans that
  are in automatic mode.
- Two install modes: `SMAppService` with Team ID requirements, and a **manual install** mode for
  personal / development use (`Support/manual-install/install.sh`, ad-hoc signatures pinned by
  cdhash in both directions).

### Helper protocol version 2

- Adds `setChargeLimitEnabled(_:reply:)` (charge limit through `CHWA`, where the Mac has it).
- Adds `setLowPowerMode(battery:ac:reply:)` (selector `setLowPowerModeWithBattery:ac:reply:`),
  which runs only `pmset -a|-b|-c lowpowermode 0|1` and `pmset -g custom`; error codes 8 and 9.
- The app checks `version(reply:)` and asks for re-registration (or for `install.sh` to be
  re-run) on a mismatch.

### Known limitations

- `SMAppService` registration with real Team ID signing, other Apple Silicon models, fanless
  Macs and long-term battery impact are not verified.
- A helper SIGKILL, crash or power loss cannot restore the fans; a reboot (or "Restore automatic
  control") is the way out.
- Many sensor keys have no known name and show up as "Sensor XXXX".

[1.0.0]: https://github.com/kinginu/FanControl/releases/tag/v1.0.0
