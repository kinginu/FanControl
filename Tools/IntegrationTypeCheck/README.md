# IntegrationTypeCheck

A scratch SwiftPM package that type-checks the DynamicNotch drop-in files (host-specific glue in
`DynamicNotchIntegration/`) and the `PATCHES.md` snippets against the real macOS SDK and the real
`FanControlCore` / `FanControlKit` / `FanControlUI`, without the host app's Xcode project. Nothing
it builds is shipped, and it is **not** part of `FanControl/Package.swift`. The host-independent UI
(settings pane, editors, chart, stored settings) is the `FanControlUI` library and is built and
tested by the package itself (`swift build`, `Tests/FanControlUITests`, which also hold the
stored-format compatibility tests that used to live here). This harness belongs to the private
DynamicNotch integration: drop it from the public tree together with `DynamicNotchIntegration/`.

## Run

```sh
cd FanControl/Tools/IntegrationTypeCheck
swift build                      # Swift 5 language mode
TYPECHECK_SWIFT6=1 swift build   # this target in the Swift 6 language mode (complete strict concurrency)
swift test                       # host store ⇄ FanControlUI store interop
```

The check passes when `Build complete!` appears with zero warnings and zero errors. It needs no
network access and has no remote dependencies, and it also works with Command Line Tools only.

## Layout

| Path | Contents |
|---|---|
| `Package.swift` | Depends only on the local package `../..` (`FanControlCore`, `FanControlKit`, `FanControlUI`) |
| `Sources/IntegrationTypeCheck/FanControl*.swift` | **Symlinks** to the drop-in files; SwiftPM compiles the link targets. After adding, renaming or removing a drop-in file, recreate the links with `find . -name 'FanControl*.swift' -type l -delete; for f in ../../../../DynamicNotchIntegration/*.swift; do ln -s "$f" .; done`. |
| `Sources/IntegrationTypeCheck/HostSettingsStore.swift` | **Symlink** to `Sources/FanControlUI/Storage/SettingsStore.swift`: the host's own settings store, as DynamicNotchApp compiles it (`Sources/Support/SettingsStorage.swift`) |
| `Tests/HostStoreInteropTests/` | A write through the host's store is read by FanControlUI's and vice versa (same keys, KVO streams) |
| `Sources/IntegrationTypeCheck/DynamicNotchStubs.swift` | Minimal stubs of the host's symbols (widget enum, grid sizes, live-activity types, settings tab ids, `Preferences`) plus copies of the host patch snippets and the app glue (host-store keys). Keep them in sync by hand. |
