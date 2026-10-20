#if os(macOS)
import os

import FanControlXPC

/// Unified logging for the helper.
///
/// - **Subsystem**: the client app's bundle identifier (`FanControlClientBundleIdentifier`), so
///   app and helper logs share it. **Category**: always `fancontrol-helper` (one category, so the
///   documented predicate keeps matching every helper line):
///   `/usr/bin/log stream --predicate 'subsystem == "<client bundle id>" AND category == "fancontrol-helper"'`
///   (DynamicNotch: `com.example.dynamicnotch.DynamicNotch`).
/// - **Areas**: every message starts with one of the prefixes
///   `Startup:`, `Config:`, `XPC:`, `Session:`, `Power:`, `Shutdown:`, so a predicate such as
///   `eventMessage BEGINSWITH "Session:"` narrows to one part of the daemon.
/// - **Levels**: `fault` = the helper cannot serve or could not hand a fan back to the SMC (a fan
///   may stay forced); `error` = an SMC or request failure; `warning` = suspicious configuration
///   or input; `notice` = state transitions (persisted: session open/close, power, shutdown);
///   `info` = connection lifecycle; `debug` = individual SMC writes.
/// - **Privacy**: every interpolation is annotated explicitly. The helper logs only pids,
///   connection ids, SMC key names/values, code-signing requirements and identifiers — no user
///   data — so all of them are `.public`.
let helperLog = Logger(subsystem: FanControlHelperConstants.appBundleIdentifier, category: "fancontrol-helper")
#endif
