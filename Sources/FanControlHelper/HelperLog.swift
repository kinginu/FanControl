#if os(macOS)
import os

import FanControlXPC

/// Unified-logging handle for the helper. The subsystem is the client app's bundle
/// identifier (`FanControlClientBundleIdentifier`), so app and helper logs share it.
/// View with: `log stream --predicate 'subsystem == "<client bundle id>" AND category == "fancontrol-helper"'`
/// (DynamicNotch: `com.example.dynamicnotch.DynamicNotch`).
let helperLog = Logger(subsystem: FanControlHelperConstants.appBundleIdentifier, category: "fancontrol-helper")
#endif
