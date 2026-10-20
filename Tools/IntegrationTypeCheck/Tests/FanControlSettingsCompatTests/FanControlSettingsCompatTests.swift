// The Fan Control settings keys read through SettingsStore exactly as sindresorhus/Defaults 8.2
// stored them (JSON strings, sorted keys). Fixture: the user's settings export of 2026-10-20
// (DynamicNotchApp/Tests/SettingsStorageTests/Fixtures); DN_SETTINGS_PLIST overrides it.
// Each test uses a throw-away UserDefaults suite.
import Foundation
import Testing
@testable import IntegrationTypeCheck

private func fixture() throws -> [String: Any] {
    let path = ProcessInfo.processInfo.environment["DN_SETTINGS_PLIST"]
        ?? URL(fileURLWithPath: #filePath)
            .appendingPathComponent("../../../../../../DynamicNotchApp/Tests/SettingsStorageTests/Fixtures/settings-2026-10-20.plist")
            .standardizedFileURL.path
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
}

private func jsonObject(_ string: String) -> NSDictionary? {
    (try? JSONSerialization.jsonObject(with: Data(string.utf8))) as? NSDictionary
}

/// Decodes the stored string (must not fall back to the default) and checks that every stored
/// field re-encodes to the same value. Returns (decoded, byte-identical).
private func roundTrip<Value: CodableStoredValue>(_ key: StoredKey<Value>, _ plist: [String: Any]) throws -> (Value, Bool)? {
    guard let stored = plist[key.name] else { return nil }
    let string = try #require(stored as? String, "\(key.name) is not a JSON string")
    let value = try #require(Value.fromStoredObject(string), "\(key.name) did not decode")
    let reencoded = try #require(value.storedObject as? String)
    let a = try #require(jsonObject(string)), b = try #require(jsonObject(reencoded))
    for case let field as String in a.allKeys {
        #expect((a[field] as? NSObject) == (b[field] as? NSObject), "\(key.name).\(field)")
    }
    print("\(key.name)\n  stored     \(string)\n  re-encoded \(reencoded)\n  decoded    \(value)")
    return (value, reencoded == string)
}

@Suite("Fan Control settings: SettingsStore reads the Defaults 8.2 format")
struct FanControlSettingsCompatTests {
    @Test func storedUserSettings() throws {
        let plist = try fixture()
        if let (general, identical) = try roundTrip(StoredKeys.fanControlGeneralSettings, plist) {
            print("  byte-identical: \(identical)")
            #expect(general.pollingInterval == 2)
        }
        if let (widget, identical) = try roundTrip(StoredKeys.fanControlWidgetSettings, plist) {
            print("  byte-identical: \(identical)")
            #expect(widget.gridSize == .doubleWide)
        }
        _ = try roundTrip(StoredKeys.fanControlThresholdSettings, plist)
    }

    @Test func readThroughStore() throws {
        let name = "FanControlSettingsCompatTests.\(UUID().uuidString)"
        let suite = try #require(UserDefaults(suiteName: name))
        defer { UserDefaults().removePersistentDomain(forName: name) }
        for (key, value) in try fixture() { suite.set(value, forKey: key) }
        let store = SettingsStore(defaults: suite)
        #expect(store[.fanControlWidgetSettings].temperatureUnit == .celsius)
        // not stored → default (90 / 95 / 5 °C)
        #expect(store[.fanControlThresholdSettings] == FanControlThresholdSettings())
        var thresholds = FanControlThresholdSettings()
        thresholds.highTemperatureAlert = 85
        store[.fanControlThresholdSettings] = thresholds
        let written = try #require(suite.string(forKey: SettingKey.fanControlThresholdSettings))
        #expect(written == #"{"alertHysteresis":5,"emergencyTemperature":95,"highTemperatureAlert":85}"#)
    }
}
