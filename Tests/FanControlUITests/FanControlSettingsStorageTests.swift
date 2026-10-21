// Stored format of the Fan Control settings keys: SettingsStore reads exactly what
// sindresorhus/Defaults 8.2 wrote (JSON strings, sorted keys). The stored strings below are the
// Fan Control entries of the user's settings export of 2026-10-20. Each test uses a throw-away
// suite.
import Foundation
import Testing
import FanControlCore
@testable import FanControlUI

private let storedGeneral = #"{"autoStartMonitoring":true,"fanAnomalyAlertEnabled":true,"highTemperatureAlertEnabled":true,"isEnabled":true,"pauseWhenNookHidden":true,"pollingInterval":2,"reapplyProfileAfterWake":true}"#
private let storedWidget = #"{"gridSize":5,"showProfilePicker":true,"showTargetRPM":false,"temperatureUnit":"celsius"}"#

private func jsonObject(_ string: String) -> NSDictionary? {
    (try? JSONSerialization.jsonObject(with: Data(string.utf8))) as? NSDictionary
}

/// Decodes `stored` (must not fall back to the default) and checks that every stored field
/// re-encodes to the same value.
private func roundTrip<Value: CodableStoredValue>(_ type: Value.Type, _ stored: String) throws -> Value {
    let value = try #require(Value.fromStoredObject(stored), "did not decode: \(stored)")
    let reencoded = try #require(value.storedObject as? String)
    let a = try #require(jsonObject(stored)), b = try #require(jsonObject(reencoded))
    for case let field as String in a.allKeys {
        #expect((a[field] as? NSObject) == (b[field] as? NSObject), "\(field)")
    }
    return value
}

private func withSuite(_ body: (UserDefaults, SettingsStore) throws -> Void) throws {
    let name = "FanControlUITests.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: name))
    defer { UserDefaults().removePersistentDomain(forName: name) }
    try body(suite, SettingsStore(defaults: suite))
}

@Suite("Fan Control settings: stored format")
struct FanControlSettingsStorageTests {

    @Test func keyNamesAreStable() {
        #expect(FanControlSettingKey.widget.name == "fanControlWidgetSettings")
        #expect(FanControlSettingKey.general.name == "fanControlGeneralSettings")
        #expect(FanControlSettingKey.thresholds.name == "fanControlThresholdSettings")
        #expect(FanControlSettingKey.temperatureWidget.name == "fanControlTemperatureWidgetSettings")
    }

    @Test func storedUserSettingsDecode() throws {
        let general = try roundTrip(FanControlGeneralSettings.self, storedGeneral)
        #expect(general.isEnabled)
        #expect(general.pollingInterval == 2)
        #expect(general.slowPollingOnBattery)   // not stored → default
        let widget = try roundTrip(FanControlWidgetSettings.self, storedWidget)
        #expect(widget.gridSize == .doubleWide)
        #expect(widget.temperatureUnit == .celsius)
        #expect(widget.showFanCurve)            // not stored → default
    }

    @Test func readAndWriteThroughStore() throws {
        try withSuite { suite, store in
            suite.set(storedWidget, forKey: StoredKeys.fanControlWidgetSettings.name)
            #expect(store[.fanControlWidgetSettings].gridSize == .doubleWide)
            // not stored → default (90 / 95 / 5 °C)
            #expect(store[.fanControlThresholdSettings] == FanControlThresholdSettings())
            var thresholds = FanControlThresholdSettings()
            thresholds.highTemperatureAlert = 85
            store[.fanControlThresholdSettings] = thresholds
            let written = try #require(suite.string(forKey: "fanControlThresholdSettings"))
            #expect(written == #"{"alertHysteresis":5,"emergencyTemperature":95,"highTemperatureAlert":85}"#)
        }
    }

    @Test func publicKeyReadsWritesAndStreams() async throws {
        let name = "FanControlUITests.\(UUID().uuidString)"
        let suite = try #require(UserDefaults(suiteName: name))
        defer { UserDefaults().removePersistentDomain(forName: name) }
        let key = FanControlSettingKey(StoredKeys.fanControlTemperatureWidgetSettings,
                                       store: SettingsStore(defaults: suite))
        #expect(key.value == FanControlTemperatureWidgetSettings())
        var updates = key.updates(initial: true).makeAsyncIterator()
        #expect(await updates.next()?.historyWindow == .fiveMinutes)
        key.value.historyWindow = .thirtyMinutes
        #expect(await updates.next()?.historyWindow == .thirtyMinutes)
        #expect(suite.string(forKey: key.name)?.contains(#""historyWindow":30"#) == true)
    }

    @Test func undecodableValueReadsAsDefault() throws {
        try withSuite { suite, store in
            suite.set(42, forKey: "fanControlGeneralSettings")
            #expect(store[.fanControlGeneralSettings] == FanControlGeneralSettings())
        }
    }
}
