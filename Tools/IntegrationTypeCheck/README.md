# IntegrationTypeCheck

A scratch SwiftPM package that type-checks SwiftUI drop-in files and host-side code snippets
against the real macOS SDK and the real `FanControlCore` / `FanControlKit`, without the host
app's Xcode project. Nothing it builds is shipped, and it is **not** part of
`FanControl/Package.swift`.

<!-- TODO: verify after refactor — this harness points at the private host's drop-in folder (`DynamicNotchIntegration/`). Once the UI becomes the `FanControlUI` product, either retarget it at that product's sources or drop it from the public tree. -->

## Run

```sh
cd FanControl/Tools/IntegrationTypeCheck
swift build                      # Swift 5 language mode
TYPECHECK_SWIFT6=1 swift build   # this target in the Swift 6 language mode (complete strict concurrency)
swift test                       # settings-storage compatibility tests
```

The check passes when `Build complete!` appears with zero warnings and zero errors. It needs no
network access and has no remote dependencies, and it also works with Command Line Tools only.

## Layout

| Path | Contents |
|---|---|
| `Package.swift` | Depends only on the local package `../..` |
| `Sources/IntegrationTypeCheck/FanControl*.swift` | **Symlinks** to the drop-in files; SwiftPM compiles the link targets. After adding or renaming a drop-in file, recreate the links with `for f in ../../../../DynamicNotchIntegration/*.swift; do ln -sf "$f" .; done`. |
| `Sources/IntegrationTypeCheck/DynamicNotchStubs.swift` | Minimal stubs of the host's symbols (widget enum, grid sizes, live-activity types, settings tab ids) plus copies of the host patch snippets. Keep them in sync by hand. |
| `Tests/FanControlSettingsCompatTests/` | Checks that stored settings keys still decode in their stored format |
