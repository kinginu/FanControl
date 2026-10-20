// The host's own SettingsStore (this module's copy of FanControlUI's Storage/SettingsStore.swift,
// as DynamicNotchApp compiles it) and FanControlUI's internal store read and write the same
// UserDefaults keys: a write through either is seen by the other, including change streams.
// (The stored-format tests are FanControl's Tests/FanControlUITests.) Uses the test process's
// standard defaults and removes the keys afterwards.
import Foundation
import Testing
import FanControlCore
import FanControlUI
@testable import IntegrationTypeCheck

@Suite("Host store ⇄ FanControlUI store", .serialized)
struct HostStoreInteropTests {

    private func cleanUp() {
        UserDefaults.standard.removeObject(forKey: FanControlSettingKey.widget.name)
        UserDefaults.standard.removeObject(forKey: FanControlSettingKey.temperatureWidget.name)
    }

    @Test func hostWriteIsReadByFanControlUI() {
        cleanUp()
        defer { cleanUp() }
        var widget = FanControlWidgetSettings()
        widget.gridSize = .doubleWide
        widget.temperatureUnit = .fahrenheit
        SettingsStore[.fanControlWidgetSettings] = widget          // host store, host key
        #expect(FanControlSettingKey.widget.value == widget)       // FanControlUI store
    }

    @Test func fanControlUIWriteIsReadByHost() {
        cleanUp()
        defer { cleanUp() }
        FanControlSettingKey.temperatureWidget.value.historyWindow = .fifteenMinutes
        #expect(SettingsStore[.fanControlTemperatureWidgetSettings].historyWindow == .fifteenMinutes)
        #expect(NookWidget.temperature.prefs.gridSizeType == .doubleWide)
    }

    @Test func fanControlUIStreamSeesHostWrite() async {
        cleanUp()
        defer { cleanUp() }
        var updates = FanControlSettingKey.widget.updates(initial: false).makeAsyncIterator()
        SettingsStore[.fanControlWidgetSettings] = FanControlWidgetSettings(gridSize: .doubleWide)
        #expect(await updates.next()?.gridSize == .doubleWide)
    }
}
