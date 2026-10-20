import Foundation

// F2: Power profiles — rules that map the Mac's power context (power source, lid,
// time window) to a fan profile and a Low Power Mode setting. Pure value types, no
// I/O; `FanControlKit.PowerProfileEngine` evaluates them. DynamicNotchApp/docs/power-profiles.md.

/// Where the Mac draws power from, as seen by a power-profile rule.
public enum PowerSourceKind: String, Codable, Hashable, Sendable {
    case ac
    case battery
}

/// Power-source condition of a rule.
public enum PowerSourceCondition: String, Codable, Hashable, Sendable, CaseIterable {
    case any
    case ac
    case battery

    public func matches(_ source: PowerSourceKind) -> Bool {
        switch self {
        case .any: return true
        case .ac: return source == .ac
        case .battery: return source == .battery
        }
    }
}

/// Lid (clamshell) condition of a rule.
///
/// `.closed` matches only when the lid is known to be closed; `.open` matches when it is
/// open **or unknown** (a Mac without a lid, or the state could not be read), so a rule
/// for "lid open" behaves like "not in clamshell mode".
public enum LidCondition: String, Codable, Hashable, Sendable, CaseIterable {
    case any
    case open
    case closed

    public func matches(isLidClosed: Bool?) -> Bool {
        switch self {
        case .any: return true
        case .open: return isLidClosed != true
        case .closed: return isLidClosed == true
        }
    }
}

/// What a rule does with Low Power Mode.
///
/// `.unchanged` leaves it alone: if Power Profiles changed it earlier, the engine returns it
/// to the value it had before (the user's own setting), see `PowerProfileEngine`.
public enum LowPowerModeAction: String, Codable, Hashable, Sendable, CaseIterable {
    case unchanged
    case on
    case off

    /// The requested state, `nil` for `.unchanged`.
    public var requestedState: Bool? {
        switch self {
        case .unchanged: return nil
        case .on: return true
        case .off: return false
        }
    }
}

/// A daily time window in local time, `[start, end)` in minutes after midnight.
///
/// - `start == end`: the whole day.
/// - `start < end`: the same day (`09:00–17:00`).
/// - `start > end`: wraps past midnight (`22:00–07:00`); the part after midnight belongs to
///   the day the window **started** (for `weekdays`).
///
/// `weekdays` uses `Calendar` numbering (1 = Sunday … 7 = Saturday); empty = every day.
public struct PowerTimeWindow: Codable, Hashable, Sendable {
    public static let minutesPerDay = 24 * 60

    public var startMinute: Int {
        didSet { startMinute = Self.clampMinute(startMinute) }
    }
    public var endMinute: Int {
        didSet { endMinute = Self.clampMinute(endMinute) }
    }
    public var weekdays: Set<Int> {
        didSet { weekdays = Self.validWeekdays(weekdays) }
    }

    public init(startMinute: Int, endMinute: Int, weekdays: Set<Int> = []) {
        self.startMinute = Self.clampMinute(startMinute)
        self.endMinute = Self.clampMinute(endMinute)
        self.weekdays = Self.validWeekdays(weekdays)
    }

    /// Convenience: `PowerTimeWindow(from: (22, 0), to: (7, 0))`.
    public init(from start: (hour: Int, minute: Int), to end: (hour: Int, minute: Int), weekdays: Set<Int> = []) {
        self.init(startMinute: start.hour * 60 + start.minute, endMinute: end.hour * 60 + end.minute,
                  weekdays: weekdays)
    }

    public var isAllDay: Bool { startMinute == endMinute }
    public var wrapsMidnight: Bool { startMinute > endMinute }

    /// Whether `date` (interpreted in `calendar`'s time zone) is inside the window.
    public func contains(_ date: Date, calendar: Calendar) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute, .weekday], from: date)
        guard let hour = parts.hour, let minute = parts.minute, let weekday = parts.weekday else { return false }
        let now = hour * 60 + minute
        let day: Int
        if isAllDay {
            day = weekday
        } else if startMinute < endMinute {
            guard now >= startMinute && now < endMinute else { return false }
            day = weekday
        } else if now >= startMinute {
            day = weekday
        } else if now < endMinute {
            day = Self.previousWeekday(weekday)
        } else {
            return false
        }
        return weekdays.isEmpty || weekdays.contains(day)
    }

    static func clampMinute(_ minute: Int) -> Int {
        min(max(minute, 0), minutesPerDay - 1)
    }

    static func validWeekdays(_ days: Set<Int>) -> Set<Int> {
        days.filter { (1...7).contains($0) }
    }

    /// 1 (Sunday) → 7 (Saturday), 2 → 1, …
    static func previousWeekday(_ weekday: Int) -> Int {
        (weekday + 5) % 7 + 1
    }

    private enum CodingKeys: String, CodingKey { case startMinute, endMinute, weekdays }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(startMinute: try container.decodeIfPresent(Int.self, forKey: .startMinute) ?? 0,
                  endMinute: try container.decodeIfPresent(Int.self, forKey: .endMinute) ?? 0,
                  weekdays: Set(try container.decodeIfPresent([Int].self, forKey: .weekdays) ?? []))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(startMinute, forKey: .startMinute)
        try container.encode(endMinute, forKey: .endMinute)
        try container.encode(weekdays.sorted(), forKey: .weekdays)
    }
}

/// The context a rule is evaluated against (supplied by `PowerContextProviding`).
///
/// macOS Focus is **not** part of the context: there is no public API that reports which
/// Focus is active (`INFocusStatusCenter` only says whether *a* Focus is on, and needs the
/// Communication Notifications entitlement, which an ad-hoc signed build cannot carry).
public struct PowerContext: Hashable, Sendable {
    public var powerSource: PowerSourceKind
    /// `true` = lid closed (clamshell), `false` = open, `nil` = no lid / unknown.
    public var isLidClosed: Bool?
    public var date: Date

    public init(powerSource: PowerSourceKind, isLidClosed: Bool?, date: Date) {
        self.powerSource = powerSource
        self.isLidClosed = isLidClosed
        self.date = date
    }
}

/// One rule: conditions (all must hold) → actions.
public struct PowerProfileRule: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Disabled rules are skipped by `PowerProfileConfiguration.firstMatch`.
    public var isEnabled: Bool
    public var powerSource: PowerSourceCondition
    public var lid: LidCondition
    /// `nil` = any time.
    public var timeWindow: PowerTimeWindow?
    /// Fan profile to activate (`FanProfile.id`); `nil` = leave the fan profile alone.
    public var fanProfileID: UUID?
    public var lowPowerMode: LowPowerModeAction

    public init(id: UUID = UUID(), name: String, isEnabled: Bool = true,
                powerSource: PowerSourceCondition = .any, lid: LidCondition = .any,
                timeWindow: PowerTimeWindow? = nil, fanProfileID: UUID? = nil,
                lowPowerMode: LowPowerModeAction = .unchanged) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.powerSource = powerSource
        self.lid = lid
        self.timeWindow = timeWindow
        self.fanProfileID = fanProfileID
        self.lowPowerMode = lowPowerMode
    }

    /// All conditions hold (`isEnabled` is not checked here).
    public func matches(_ context: PowerContext, calendar: Calendar) -> Bool {
        guard powerSource.matches(context.powerSource) else { return false }
        guard lid.matches(isLidClosed: context.isLidClosed) else { return false }
        if let timeWindow, !timeWindow.contains(context.date, calendar: calendar) { return false }
        return true
    }

    /// The rule has no condition at all (matches everything): a catch-all, useful last.
    public var isCatchAll: Bool {
        powerSource == .any && lid == .any && timeWindow == nil
    }

    /// The rule changes nothing (no fan profile, Low Power Mode unchanged).
    public var hasNoAction: Bool {
        fanProfileID == nil && lowPowerMode == .unchanged
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, isEnabled, powerSource, lid, timeWindow, fanProfileID, lowPowerMode
    }

    /// Tolerant decoding: missing or unknown values fall back to the defaults, so a store
    /// written by a newer build (extra cases) still loads.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        powerSource = (try? container.decodeIfPresent(PowerSourceCondition.self, forKey: .powerSource)) ?? .any
        lid = (try? container.decodeIfPresent(LidCondition.self, forKey: .lid)) ?? .any
        timeWindow = try? container.decodeIfPresent(PowerTimeWindow.self, forKey: .timeWindow)
        fanProfileID = try? container.decodeIfPresent(UUID.self, forKey: .fanProfileID)
        lowPowerMode = (try? container.decodeIfPresent(LowPowerModeAction.self, forKey: .lowPowerMode)) ?? .unchanged
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(powerSource, forKey: .powerSource)
        try container.encode(lid, forKey: .lid)
        try container.encodeIfPresent(timeWindow, forKey: .timeWindow)
        try container.encodeIfPresent(fanProfileID, forKey: .fanProfileID)
        try container.encode(lowPowerMode, forKey: .lowPowerMode)
    }
}

public extension PowerProfileRule {
    /// Starter rules offered by the settings pane ("Add Rule" menu). Plain English names.
    static func templates() -> [PowerProfileRule] {
        [
            PowerProfileRule(name: "On Battery", powerSource: .battery,
                             fanProfileID: FanProfile.BuiltInID.automatic, lowPowerMode: .on),
            PowerProfileRule(name: "Clamshell on Power Adapter", powerSource: .ac, lid: .closed,
                             fanProfileID: FanProfile.BuiltInID.boost, lowPowerMode: .off),
            PowerProfileRule(name: "Quiet Nights", timeWindow: PowerTimeWindow(from: (22, 0), to: (7, 0)),
                             fanProfileID: FanProfile.BuiltInID.constantQuiet),
        ]
    }
}

/// The persisted power-profile settings: master switch + ordered rules (first match wins).
public struct PowerProfileConfiguration: Codable, Hashable, Sendable {
    public static let schemaVersion = 1

    /// Off by default: nothing is switched until the user turns Power Profiles on.
    public var isEnabled: Bool
    public var rules: [PowerProfileRule]

    public init(isEnabled: Bool = false, rules: [PowerProfileRule] = []) {
        self.isEnabled = isEnabled
        self.rules = rules
    }

    /// The first enabled rule whose conditions hold (`nil` when the configuration is off).
    public func firstMatch(in context: PowerContext, calendar: Calendar) -> PowerProfileRule? {
        guard isEnabled else { return nil }
        return rules.first { $0.isEnabled && $0.matches(context, calendar: calendar) }
    }

    /// Rules after an enabled catch-all can never match (shown as a hint by the editor).
    public var unreachableRuleIDs: Set<UUID> {
        guard let index = rules.firstIndex(where: { $0.isEnabled && $0.isCatchAll }) else { return [] }
        return Set(rules[(index + 1)...].map(\.id))
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, isEnabled, rules }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        rules = try container.decodeIfPresent([PowerProfileRule].self, forKey: .rules) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schemaVersion, forKey: .schemaVersion)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(rules, forKey: .rules)
    }

    public static func encodeJSON(_ configuration: PowerProfileConfiguration) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(configuration)
    }

    public static func decodeJSON(_ data: Data) throws -> PowerProfileConfiguration {
        try JSONDecoder().decode(PowerProfileConfiguration.self, from: data)
    }
}
