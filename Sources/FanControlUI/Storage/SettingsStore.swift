#if os(macOS)
// FanControlUI's settings storage: a first-party store on top of `UserDefaults`
// (replaced sindresorhus/Defaults on 2026-10-20). Everything here is `internal`:
// hosts read and write the Fan Control settings through the public
// `FanControlSettingKey` / `@FanControlSetting` (FanControlSettingKey.swift).
//
// Shared source: DynamicNotchApp compiles this same file into its own module through
// the symlink `DynamicNotchApp/Sources/Support/SettingsStorage.swift` (its app-wide
// settings use the same store; its key names are in `Sources/Support/SettingKey.swift`).
// Keep the file free of host keys and access modifiers so both modules compile it.
// Both copies observe `UserDefaults.standard` by KVO, so a write from either reaches
// the other's views.
//
// Storage format — byte-compatible with what Defaults 8.2 wrote, so existing
// user settings load unchanged:
//
//   value type                         stored object under the key name
//   ---------------------------------  ------------------------------------------
//   Codable (`CodableStoredValue`)     String: JSON from `JSONEncoder()` with
//                                      `.sortedKeys` (Defaults.CodableBridge);
//                                      decoded with a default `JSONDecoder()`.
//                                      A non-string / undecodable object reads
//                                      as the key's default value.
//   Bool, Int, Double, Float, String,  the native property-list object
//   Data, Date
//   Array / [String: V]                plist array / dictionary of the elements'
//                                      stored objects (native elements stay
//                                      native, Codable elements become JSON
//                                      strings — Defaults.ArrayBridge)
//   RawRepresentable (`RawStoredValue`) the raw value's stored object
//   Optional                           nil removes the key
//
// Change notifications use KVO on the `UserDefaults` suite (as Defaults did), so
// writes from anywhere — this store, `UserDefaults.standard.set`, another
// process via `defaults write` — reach `@StoredSetting` views and
// `SettingsStore.updates(…)` streams.

import Foundation
import Observation
import SwiftUI

// MARK: - Value encoding

/// A value that can be stored in `UserDefaults` by `SettingsStore`. (`SendableMetatype`:
/// the change streams decode values from the writer's thread.)
protocol StoredValue: SendableMetatype {
    /// The property-list object written under the key; `nil` removes the key.
    var storedObject: Any? { get }
    /// Decodes a value read from `UserDefaults`; `nil` means "use the default".
    static func fromStoredObject(_ object: Any) -> Self?
}

/// Codable settings stored as a JSON string (sorted keys), exactly like
/// Defaults' `CodableBridge`. Conform settings structs to this.
protocol CodableStoredValue: StoredValue, Codable {}

extension CodableStoredValue {
    var storedObject: Any? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func fromStoredObject(_ object: Any) -> Self? {
        guard let string = object as? String else { return nil }
        return try? JSONDecoder().decode(Self.self, from: Data(string.utf8))
    }
}

/// Enums stored by raw value (Defaults' `RawRepresentableBridge`). Note: an enum
/// that was `Codable & Defaults.Serializable` was stored by Defaults as a JSON
/// string (`"\"value\""`); conform such an enum to `CodableStoredValue` instead.
protocol RawStoredValue: StoredValue, RawRepresentable where RawValue: StoredValue {}

extension RawStoredValue {
    var storedObject: Any? { rawValue.storedObject }

    static func fromStoredObject(_ object: Any) -> Self? {
        RawValue.fromStoredObject(object).flatMap(Self.init(rawValue:))
    }
}

/// Native property-list scalars: stored as themselves.
private protocol NativeStoredValue: StoredValue {}

extension NativeStoredValue {
    var storedObject: Any? { self }
    static func fromStoredObject(_ object: Any) -> Self? { object as? Self }
}

extension Bool: StoredValue, NativeStoredValue {}
extension Int: StoredValue, NativeStoredValue {}
extension Double: StoredValue, NativeStoredValue {}
extension Float: StoredValue, NativeStoredValue {}
extension String: StoredValue, NativeStoredValue {}
extension Data: StoredValue, NativeStoredValue {}
extension Date: StoredValue, NativeStoredValue {}

extension Array: StoredValue where Element: StoredValue {
    var storedObject: Any? { map { $0.storedObject ?? NSNull() } }

    static func fromStoredObject(_ object: Any) -> Self? {
        guard let array = object as? [Any] else { return nil }
        let elements = array.compactMap(Element.fromStoredObject)
        return elements.count == array.count ? elements : nil
    }
}

extension Dictionary: StoredValue where Key == String, Value: StoredValue {
    var storedObject: Any? { compactMapValues(\.storedObject) }

    static func fromStoredObject(_ object: Any) -> Self? {
        guard let dictionary = object as? [String: Any] else { return nil }
        let values = dictionary.compactMapValues(Value.fromStoredObject)
        return values.count == dictionary.count ? values : nil
    }
}

extension Optional: StoredValue where Wrapped: StoredValue {
    var storedObject: Any? { self?.storedObject }

    static func fromStoredObject(_ object: Any) -> Self? {
        Wrapped.fromStoredObject(object).map(Optional.some)
    }
}

// MARK: - Typed keys

/// Namespace of the typed setting keys. Declare keys in extensions, Defaults-style:
///
///     extension StoredKeys {
///         static let nookSettings = Key<NookSettings>("nookSettings", default: .init())
///     }
///
/// and use them as `.nookSettings` (`SettingsStore[.nookSettings]`,
/// `@StoredSetting(.nookSettings)`, `SettingsStore.updates(.nookSettings)`).
/// (A class so that the static keys declared on it are visible through the
/// generic subclass, which is what makes the implicit `.name` syntax work.)
class StoredKeys: @unchecked Sendable {
    typealias Key<Value: StoredValue> = StoredKey<Value>

    /// The UserDefaults key name (the on-disk identity of the setting: never rename one).
    let name: String

    fileprivate init(name: String) {
        self.name = name
    }
}

/// A setting stored under `name` with a default used when nothing (or nothing
/// decodable) is stored.
final class StoredKey<Value: StoredValue>: StoredKeys, @unchecked Sendable {
    let defaultValue: Value

    init(_ name: String, default defaultValue: Value) {
        self.defaultValue = defaultValue
        super.init(name: name)
    }
}

// MARK: - Store

/// The settings store (one per process, `SettingsStore.shared`, on
/// `UserDefaults.standard`).
///
/// Reads and writes are thread-safe (`UserDefaults` is) and can be made from any
/// isolation; each read decodes the stored object, like Defaults did (no cache).
/// The store is `Observable` with per-key granularity: reading a key through
/// `observedValue(_:)` (what `@StoredSetting` does) inside SwiftUI's `body` or
/// `withObservationTracking` registers a dependency on that key only, and any
/// change to it — from this store or any other writer of the suite — invalidates
/// it (delivered on the main thread).
final class SettingsStore: Observable, @unchecked Sendable {
    static let shared = SettingsStore(defaults: .standard)

    let defaults: UserDefaults

    private let registrar = ObservationRegistrar()
    private let lock = NSLock()
    /// Keys whose KVO notifications feed the Observation registrar.
    private var observedNames: Set<String> = []
    private var observer: DefaultsKeyObserver?

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    // MARK: Typed access

    /// The stored value, or the key's default when nothing decodable is stored.
    func value<Value>(_ key: StoredKey<Value>) -> Value {
        guard let object = defaults.object(forKey: key.name) else { return key.defaultValue }
        return Value.fromStoredObject(object) ?? key.defaultValue
    }

    /// Writes `value` (a `nil` stored object removes the key).
    func set<Value>(_ value: Value, for key: StoredKey<Value>) {
        if let object = value.storedObject {
            defaults.set(object, forKey: key.name)
        } else {
            defaults.removeObject(forKey: key.name)
        }
    }

    /// Removes the stored value, so the key reads as its default again.
    func reset(_ keys: StoredKeys...) {
        for key in keys { defaults.removeObject(forKey: key.name) }
    }

    /// `true` when nothing is stored under the key.
    func isDefault(_ key: StoredKeys) -> Bool {
        defaults.object(forKey: key.name) == nil
    }

    subscript<Value>(key: StoredKey<Value>) -> Value {
        get { value(key) }
        set { set(newValue, for: key) }
    }

    /// `SettingsStore[.x]` — the shared store (the former `Defaults[.x]`).
    static subscript<Value>(key: StoredKey<Value>) -> Value {
        get { shared.value(key) }
        set { shared.set(newValue, for: key) }
    }

    // MARK: Observation

    /// Like `value(_:)`, and registers an Observation dependency on the key.
    func observedValue<Value>(_ key: StoredKey<Value>) -> Value {
        track(key.name)
        return value(key)
    }

    /// Registers an Observation access for `name` (and starts watching it).
    func track(_ name: String) {
        startObserving(name)
        registrar.access(self, keyPath: \.[revisionOf: name])
    }

    /// Observation anchor for one key: the key path `\.[revisionOf: name]` is
    /// what views depend on; the value itself is irrelevant.
    subscript(revisionOf name: String) -> Int { 0 }

    private func startObserving(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !observedNames.contains(name) else { return }
        observedNames.insert(name)
        if observer == nil {
            observer = DefaultsKeyObserver(defaults: defaults) { [weak self] name in
                self?.keyDidChange(name)
            }
        }
        observer?.add(name)
    }

    private func keyDidChange(_ name: String) {
        let notify: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            self.registrar.withMutation(of: self, keyPath: \.[revisionOf: name]) {}
        }
        if Thread.isMainThread { notify() } else { DispatchQueue.main.async(execute: notify) }
    }

    // MARK: Change streams

    /// The key's values as they change (the former `Defaults.updates(key, initial:)`).
    /// With `initial`, the current value is yielded first. Values are yielded on the
    /// writer's thread, for every write (not de-duplicated).
    static func updates<Value>(_ key: StoredKey<Value>, initial: Bool = true,
                               store: SettingsStore = .shared) -> AsyncStream<Value> {
        AsyncStream { continuation in
            if initial { continuation.yield(store.value(key)) }
            let observer = DefaultsKeyObserver(defaults: store.defaults) { _ in
                continuation.yield(store.value(key))
            }
            observer.add(key.name)
            continuation.onTermination = { _ in observer.invalidate() }
        }
    }

    /// One element per change of any of `keys` (the former `Defaults.updates([keys], initial:)`).
    static func updates(_ keys: [StoredKeys], initial: Bool = true,
                        store: SettingsStore = .shared) -> AsyncStream<Void> {
        AsyncStream { continuation in
            if initial { continuation.yield() }
            let observer = DefaultsKeyObserver(defaults: store.defaults) { _ in
                continuation.yield()
            }
            for key in keys { observer.add(key.name) }
            continuation.onTermination = { _ in observer.invalidate() }
        }
    }
}

// MARK: - KVO

/// KVO observer of a set of `UserDefaults` keys. Calls `onChange` with the key
/// name on the writer's thread. Removes its observations on `invalidate()` / deinit.
private final class DefaultsKeyObserver: NSObject, @unchecked Sendable {
    private let defaults: UserDefaults
    private let onChange: @Sendable (String) -> Void
    private let lock = NSLock()
    private var names: Set<String> = []
    private var isValid = true

    init(defaults: UserDefaults, onChange: @escaping @Sendable (String) -> Void) {
        self.defaults = defaults
        self.onChange = onChange
        super.init()
    }

    func add(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        guard isValid, names.insert(name).inserted else { return }
        defaults.addObserver(self, forKeyPath: name, options: [.new], context: nil)
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        guard isValid else { return }
        isValid = false
        for name in names { defaults.removeObserver(self, forKeyPath: name, context: nil) }
        names.removeAll()
    }

    deinit {
        invalidate()
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard let keyPath else { return }
        onChange(keyPath)
    }
}

// MARK: - Property wrapper

/// A stored setting as a property (the former `@Default(.x)`):
///
///     @StoredSetting(.nookSettings) private var nookSettings
///     @StoredSetting("intro") private var intro = true   // untyped name + default
///
/// In SwiftUI views the view re-renders when the setting changes (through the
/// store's Observation tracking); `$x` is a `Binding`. Also usable in non-view code.
@propertyWrapper
struct StoredSetting<Value: StoredValue>: DynamicProperty {
    let key: StoredKey<Value>
    let store: SettingsStore

    init(_ key: StoredKey<Value>, store: SettingsStore = .shared) {
        self.key = key
        self.store = store
    }

    /// `@StoredSetting("x") var x = defaultValue`
    init(wrappedValue defaultValue: Value, _ name: String, store: SettingsStore = .shared) {
        self.init(StoredKey(name, default: defaultValue), store: store)
    }

    var wrappedValue: Value {
        get { store.observedValue(key) }
        nonmutating set { store.set(newValue, for: key) }
    }

    var projectedValue: Binding<Value> {
        let key = key
        let store = store
        return Binding(get: { store.observedValue(key) }, set: { store.set($0, for: key) })
    }

    /// Removes the stored value (reads as the default again).
    func reset() { store.reset(key) }

    /// `true` when nothing is stored under the key.
    var isDefaultValue: Bool { store.isDefault(key) }
}
#endif
