import Testing

/// Tags shared by the FanControl test targets (each target declares the same set):
/// `swift test --filter` selects by name, Xcode's test navigator and `--skip` by tag.
extension Tag {
    /// SMC keys, codec, readers and the key layout of writes.
    @Tag static var smc: Self
    /// `HelperClient`, the retry gate, `HelperInstaller` and the helper's write / power policies.
    @Tag static var helper: Self
    /// Real `NSXPCConnection` to the in-process `FakeHelper`.
    @Tag static var endToEnd: Self
    /// Manual installation, identifiers, code-signing requirements, scripts.
    @Tag static var install: Self
    /// Fan targets: engine, curves, stabilizer, write strategy.
    @Tag static var control: Self
    /// Temperature sensors: catalog, filter, aggregates, history.
    @Tag static var sensors: Self
    /// Alerts, emergency override, thresholds.
    @Tag static var safety: Self
    /// Profiles and their persistence.
    @Tag static var profiles: Self
    /// Sleep / wake and power-source aware polling.
    @Tag static var power: Self
    /// `FanControlManager` and its components.
    @Tag static var manager: Self
    /// Actor / queue isolation.
    @Tag static var concurrency: Self
    /// Takes more than a second (waits out a real backoff).
    @Tag static var slow: Self
}
