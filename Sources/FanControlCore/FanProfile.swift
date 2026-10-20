import Foundation

/// A named set of per-fan modes.
///
/// The app offers a fixed set of seven profiles (`ProfileStore`, `FanProfile.fixedProfileIDs`):
/// Automatic, Constant Quiet, Constant High, Boost, Max (read-only presets) and
/// Custom 1 / Custom 2 (user-editable slots). Their identifiers, parameters and factory
/// functions are in FanProfile+Presets.swift.
///
/// Resolution for one fan: `mode(for:)` (its `modes` entry, else `defaultMode`, else
/// `.automatic`) and, for a `.sensor` mode, `curve(for:)` (the stored matching curve, else
/// the mode's linear ramp).
public struct FanProfile: Identifiable, Codable, Hashable, Sendable {
    /// Stable identifier (fixed for the built-in profiles: `BuiltInID`).
    public var id: UUID
    /// Display name. The fixed profiles use `DefaultName`; the app localizes those.
    public var name: String
    /// Mode per fan, keyed by `FanDevice.id`. Fans without an entry use
    /// `defaultMode` (or `.automatic` when that is `nil`). An explicit
    /// `.automatic` entry overrides `defaultMode`.
    public var modes: [Int: FanControlMode]
    /// Built-in profiles cannot be deleted from a `ProfileStore`. `true` for
    /// the presets (Automatic, Constant Quiet, Constant High, Boost, Max) and the
    /// legacy Silent / Maximum; `false` for the Custom 1 / Custom 2 slots.
    public var isBuiltIn: Bool
    /// Mode for every fan that has no entry in `modes` ("every fan" presets,
    /// which are defined before the fans are known). `nil` = `.automatic`.
    ///
    /// `FanControlManager.applyProfile` opens the write session when `modes`
    /// or `defaultMode` holds a manual mode, so an unresolved preset works.
    /// Planning (`FanControlEngine.plan`) uses `mode(for:)` and therefore
    /// honours `defaultMode` as stored. UIs still pass `resolved(for:)` to show
    /// and store explicit per-fan modes.
    public var defaultMode: FanControlMode?
    /// Multi-point curves of the `.sensor` modes in `modes`, keyed by fan id. A curve
    /// applies only while its first / last temperature equal the mode's
    /// `startTemperature` / `maxTemperature` (`FanCurve.matches`); otherwise (the mode
    /// was edited by a curve-unaware editor) the mode's linear ramp is used.
    public var curves: [Int: FanCurve]
    /// Curve of `defaultMode` when that is `.sensor` (same matching rule); used by fans
    /// without a `modes` entry.
    public var defaultCurve: FanCurve?

    public init(id: UUID = UUID(), name: String, modes: [Int: FanControlMode] = [:], isBuiltIn: Bool = false,
                defaultMode: FanControlMode? = nil, curves: [Int: FanCurve] = [:], defaultCurve: FanCurve? = nil) {
        self.id = id
        self.name = name
        self.modes = modes
        self.isBuiltIn = isBuiltIn
        self.defaultMode = defaultMode
        self.curves = curves
        self.defaultCurve = defaultCurve
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case id, name, modes, isBuiltIn, defaultMode, curves, defaultCurve
    }

    /// `modes`, `isBuiltIn`, `curves` and `defaultCurve` are optional in the JSON
    /// (profiles stored before curves existed decode with empty curves).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        modes = try c.decodeIfPresent([Int: FanControlMode].self, forKey: .modes) ?? [:]
        isBuiltIn = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        defaultMode = try c.decodeIfPresent(FanControlMode.self, forKey: .defaultMode)
        curves = try c.decodeIfPresent([Int: FanCurve].self, forKey: .curves) ?? [:]
        defaultCurve = try c.decodeIfPresent(FanCurve.self, forKey: .defaultCurve)
    }

    /// Omits `curves` when empty and `defaultMode` / `defaultCurve` when `nil`.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(modes, forKey: .modes)
        try c.encode(isBuiltIn, forKey: .isBuiltIn)
        try c.encodeIfPresent(defaultMode, forKey: .defaultMode)
        if !curves.isEmpty { try c.encode(curves, forKey: .curves) }
        try c.encodeIfPresent(defaultCurve, forKey: .defaultCurve)
    }

    // MARK: Resolution

    /// `true` for the Custom 1 / Custom 2 slots.
    public var isCustomSlot: Bool { Self.customSlotIDs.contains(id) }

    /// The mode configured for `fan`: its `modes` entry, else `defaultMode`,
    /// else `.automatic`.
    public func mode(for fan: FanDevice) -> FanControlMode {
        modes[fan.id] ?? defaultMode ?? .automatic
    }

    /// The stored curve for `fan` (its `curves` entry when it has a `modes` entry, else
    /// `defaultCurve`), whether or not it matches the mode.
    public func storedCurve(for fan: FanDevice) -> FanCurve? {
        modes[fan.id] != nil ? curves[fan.id] : defaultCurve
    }

    /// The curve that drives `fan`, or `nil` unless its mode is `.sensor`:
    /// the stored curve when it matches the mode's start / max temperatures, else the
    /// two-point linear curve of the mode (`FanCurve.linear`), or `nil` for a degenerate
    /// mode (`startTemperature >= maxTemperature` or non-finite: step / fail-loud rule of
    /// `FanControlEngine`).
    public func curve(for fan: FanDevice) -> FanCurve? {
        let mode = mode(for: fan)
        guard mode.isSensorBased else { return nil }
        if let stored = storedCurve(for: fan), Self.curve(stored, drives: mode) {
            return stored
        }
        return mode.linearCurve
    }

    // MARK: Editing

    /// Makes fan `fanID` (or, with `nil`, every fan without a `modes` entry) follow
    /// `sensorKey` on `curve`: sets the mode to `.sensor(sensorKey, first, last)` (the
    /// curve's normalized first / last temperatures) and stores the normalized curve.
    /// An empty curve (after normalization) is ignored.
    public mutating func setCurve(_ curve: FanCurve, sensorKey: String, forFan fanID: Int?) {
        let normalized = curve.normalized()
        guard let first = normalized.points.first?.temperature, let last = normalized.points.last?.temperature
        else { return }
        let mode = FanControlMode.sensor(sensorKey: sensorKey, startTemperature: first, maxTemperature: last)
        if let fanID {
            modes[fanID] = mode
            curves[fanID] = normalized
        } else {
            defaultMode = mode
            defaultCurve = normalized
        }
    }

    /// Drops curves that do not drive a `.sensor` mode any more (mode changed, or its
    /// start / max no longer match the curve).
    public mutating func removeStaleCurves() {
        curves = curves.filter { fan, curve in modes[fan].map { Self.curve(curve, drives: $0) } ?? false }
        if let defaultCurve, !(defaultMode.map { Self.curve(defaultCurve, drives: $0) } ?? false) {
            self.defaultCurve = nil
        }
    }

    /// A copy with an explicit `modes` entry for every fan in `fans`
    /// (`mode(for:)`; `.automatic` fans get no entry unless `defaultMode`
    /// is manual, in which case `.automatic` is stored explicitly).
    /// `defaultMode` is kept for fans not in `fans`. Each materialized fan also gets
    /// its stored curve (`storedCurve(for:)`) in `curves`. Pass this to
    /// `FanControlManager.applyProfile`, which opens the write session only
    /// when `modes` contains a manual mode.
    public func resolved(for fans: [FanDevice]) -> FanProfile {
        var copy = self
        let defaultIsManual = defaultMode?.isManual ?? false
        for fan in fans {
            let mode = mode(for: fan)
            if mode.isManual || defaultIsManual {
                copy.modes[fan.id] = mode
                copy.curves[fan.id] = storedCurve(for: fan)
            } else {
                copy.modes[fan.id] = nil
                copy.curves[fan.id] = nil
            }
        }
        return copy
    }

    /// `true` if `curve` belongs to `mode`: a `.sensor` mode whose start / max
    /// temperatures equal the curve's first / last (`FanCurve.matches`).
    static func curve(_ curve: FanCurve, drives mode: FanControlMode) -> Bool {
        guard case .sensor(_, let start, let max) = mode else { return false }
        return curve.matches(startTemperature: start, maxTemperature: max)
    }
}
