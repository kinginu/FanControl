// FanControlHelper: privileged launchd daemon registered by the host app through
// `SMAppService.daemon(plistName:)`, or installed by `Support/manual-install/install.sh`
// as a plain LaunchDaemon (manual / personal mode). launchd starts it on demand when the
// app connects to the Mach service; it then serves `FanControlHelperProtocol`.
// Bootstrap, command line and exit statuses: `HelperDaemon.swift`.
#if os(macOS)
HelperDaemon.run(arguments: CommandLine.arguments)
#else
print("FanControlHelper is macOS-only")
#endif
