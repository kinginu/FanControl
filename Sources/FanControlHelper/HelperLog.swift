#if os(macOS)
import os

/// Unified-logging handle for the helper.
/// View with: `log stream --predicate 'subsystem == "com.example.dynamicnotch.DynamicNotch" AND category == "fancontrol-helper"'`
let helperLog = Logger(subsystem: "com.example.dynamicnotch.DynamicNotch", category: "fancontrol-helper")
#endif
