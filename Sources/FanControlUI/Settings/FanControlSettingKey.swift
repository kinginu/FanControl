#if os(macOS)
// Public access to the Fan Control settings stored in `UserDefaults.standard`.
//
// The store itself (`SettingsStore`, `StoredKey`, `@StoredSetting`; Storage/SettingsStore.swift)
// is internal. Hosts use the typed keys below:
//
//     @FanControlSetting(.widget) private var settings      // SwiftUI: re-renders on change
//     $settings.temperatureUnit                             // Binding
//     FanControlSettingKey.general.value.isEnabled          // read anywhere
//     for await general in FanControlSettingKey.general.updates() { … }
//
// The key names are the on-disk identity of the user's settings (the former
// sindresorhus/Defaults key names, stored as sorted-key JSON strings): never rename one.
// A host that keeps its own store on the same `UserDefaults` (DynamicNotchApp does) reads the
// same values under `FanControlSettingKey<…>.name`.

import Foundation
import SwiftUI

// MARK: - Key names (internal typed keys)

extension StoredKeys {
    static let fanControlWidgetSettings = Key<FanControlWidgetSettings>(
        "fanControlWidgetSettings", default: .init())
    static let fanControlGeneralSettings = Key<FanControlGeneralSettings>(
        "fanControlGeneralSettings", default: .init())
    static let fanControlThresholdSettings = Key<FanControlThresholdSettings>(
        "fanControlThresholdSettings", default: .init())
    static let fanControlTemperatureWidgetSettings = Key<FanControlTemperatureWidgetSettings>(
        "fanControlTemperatureWidgetSettings", default: .init())
}

// MARK: - Public key

/// A Fan Control setting stored in `UserDefaults.standard`: `.widget`, `.general`,
/// `.thresholds`, `.temperatureWidget`.
public struct FanControlSettingKey<Value: Sendable>: Sendable {

    /// The `UserDefaults` key name.
    public let name: String
    /// The value used when nothing (or nothing decodable) is stored.
    public let defaultValue: Value

    private let read: @Sendable () -> Value
    private let write: @Sendable (Value) -> Void
    private let stream: @Sendable (Bool) -> AsyncStream<Value>

    /// The stored value (or the default). Reading it inside a SwiftUI `body` (or
    /// `withObservationTracking`) tracks this key; setting it writes `UserDefaults.standard`.
    public var value: Value {
        get { read() }
        nonmutating set { write(newValue) }
    }

    /// The values as they change (with `initial`, the current value first). Values are yielded
    /// on the writer's thread, once per write.
    public func updates(initial: Bool = true) -> AsyncStream<Value> {
        stream(initial)
    }
}

extension FanControlSettingKey where Value: StoredValue {
    init(_ key: StoredKey<Value>, store: SettingsStore = .shared) {
        name = key.name
        defaultValue = key.defaultValue
        read = { store.observedValue(key) }
        write = { store.set($0, for: key) }
        stream = { SettingsStore.updates(key, initial: $0, store: store) }
    }
}

extension FanControlSettingKey where Value == FanControlWidgetSettings {
    /// Fan Control widget layout, visible fans and the temperature unit shared by every view.
    public static var widget: Self { Self(StoredKeys.fanControlWidgetSettings) }
}

extension FanControlSettingKey where Value == FanControlGeneralSettings {
    /// Master switch, polling, lifecycle and alert toggles (Settings ▸ General).
    public static var general: Self { Self(StoredKeys.fanControlGeneralSettings) }
}

extension FanControlSettingKey where Value == FanControlThresholdSettings {
    /// Alert / emergency / hysteresis temperatures (Settings ▸ General).
    public static var thresholds: Self { Self(StoredKeys.fanControlThresholdSettings) }
}

extension FanControlSettingKey where Value == FanControlTemperatureWidgetSettings {
    /// Temperature widget window and series.
    public static var temperatureWidget: Self { Self(StoredKeys.fanControlTemperatureWidgetSettings) }
}

// MARK: - Property wrapper

/// A Fan Control setting as a SwiftUI property (`@FanControlSetting(.widget) var settings`).
/// The view re-renders when the setting changes (from any writer of `UserDefaults.standard`);
/// `$settings` is a `Binding`.
@propertyWrapper
public struct FanControlSetting<Value: Sendable>: DynamicProperty {
    public let key: FanControlSettingKey<Value>

    public init(_ key: FanControlSettingKey<Value>) {
        self.key = key
    }

    public var wrappedValue: Value {
        get { key.value }
        nonmutating set { key.value = newValue }
    }

    public var projectedValue: Binding<Value> {
        let key = key
        return Binding(get: { key.value }, set: { key.value = $0 })
    }
}
#endif
