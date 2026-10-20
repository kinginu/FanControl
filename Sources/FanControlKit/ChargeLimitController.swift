import FanControlCore
import FanControlXPC

/// What the app read from the SMC's `CHWA` key (`ChargeLimitController.reading`).
public enum ChargeLimitReading: Equatable, Sendable {
    /// Not read yet.
    case unknown
    /// `CHWA` = 1: the firmware holds the battery at 80 %.
    case on
    /// `CHWA` = 0: normal charging.
    case off
    /// No usable `CHWA` key on this Mac (absent, unexpected layout, not writable,
    /// or not an Apple Silicon Mac). The associated text says why.
    case unsupported(String)
    /// The key exists but its value could not be read or is not 0/1.
    case unreadable(String)
}

/// What a UI shows for "Limit charging to 80 %" (`ChargeLimitController.status`).
public enum ChargeLimitStatus: Equatable, Sendable {
    /// Not read yet.
    case unknown
    case on
    case off
    /// Not available on this Mac (hide or disable the control).
    case unsupported(String)
    /// The key exists but its value is unknown (`ChargeLimitReading.unreadable`).
    /// Turning the limit off is still possible (0 is the firmware default).
    case unreadable(String)
    /// The key is usable but the privileged helper is not installed for this app
    /// (or refuses it), so the state can be shown (`isOn`, `nil` if unreadable) but
    /// not changed until the helper is installed. A change attempt still goes
    /// through the same install path as a fan write (`prepareHelper`).
    case needsHelper(isOn: Bool?)

    /// `true` for `.on` and `.needsHelper(isOn: true)`.
    public var isOn: Bool {
        switch self {
        case .on, .needsHelper(isOn: true): return true
        default: return false
        }
    }

    /// `false` for `.unsupported` and `.unknown`.
    public var isAvailable: Bool {
        switch self {
        case .unsupported, .unknown: return false
        default: return true
        }
    }
}

#if os(macOS)
import Foundation
import Observation
import FanControlSMC

/// The helper operations `ChargeLimitController` needs (`HelperCoordinator` in the
/// app, a fake in tests).
@MainActor
protocol ChargeLimitHelperAccess: AnyObject {
    /// The helper is installed for this app and has not rejected it.
    var isHelperUsable: Bool { get }
    /// Re-reads the install status (file / `SMAppService` reads only).
    func refreshHelperStatus()
    /// Install if needed + protocol version check (the fan-write path, without a session).
    func prepareHelper() async throws
    /// `HelperClient.setChargeLimitEnabled(_:)`: the read-back value.
    func setChargeLimitEnabled(_ enabled: Bool) async throws -> Int
}

/// "Limit charging to 80 %" (Apple Silicon SMC key `CHWA`, docs/helper.md
/// "Charge limit (CHWA)").
///
/// - Reading is unprivileged: `refresh()` opens a short-lived AppleSMC connection
///   off the main actor and reads `CHWA` (`reading`). Nothing is written.
/// - Changing it (`setEnabled(_:)`) is an explicit user action only: the helper is
///   prepared exactly like for a fan write (`HelperCoordinator.prepareHelper()`:
///   install if needed, protocol version check) and then asked through the
///   dedicated `setChargeLimitEnabled` request. No fan write session is opened.
/// - The state lives in the SMC, not in the app: it is not reverted when the app
///   quits, fan control stops or the helper exits, and the app never re-applies it
///   on its own (an SMC reset clears it; the UI then shows Off).
///
/// Available as `FanControlManager.shared.chargeLimit`.
@MainActor
@Observable
public final class ChargeLimitController {

    /// The last value read from the SMC (or reported back by the helper).
    public private(set) var reading: ChargeLimitReading = .unknown
    /// `true` while `setEnabled(_:)` runs.
    public private(set) var isBusy = false
    /// The last failure of `setEnabled(_:)` (cleared by the next successful change
    /// and by `clearError()`).
    public private(set) var lastError: FanControlError?
    /// When `reading` was last refreshed.
    public private(set) var lastRefresh: Date?
    /// Mirrors `helper.isHelperUsable` (refreshed by `refresh()` and after changes).
    public private(set) var isHelperUsable = false

    /// UI status combining `reading` and `isHelperUsable`.
    public var status: ChargeLimitStatus {
        switch reading {
        case .unknown: return .unknown
        case .unsupported(let reason): return .unsupported(reason)
        case .unreadable(let reason): return isHelperUsable ? .unreadable(reason) : .needsHelper(isOn: nil)
        case .on: return isHelperUsable ? .on : .needsHelper(isOn: true)
        case .off: return isHelperUsable ? .off : .needsHelper(isOn: false)
        }
    }

    /// User-facing text for `lastError` (`message(for:)`), `nil` if none.
    public var errorMessage: String? { lastError.map(Self.message(for:)) }

    /// Reads the current state off the main actor.
    typealias Reader = @Sendable () async -> ChargeLimitReading

    @ObservationIgnored private weak var helper: (any ChargeLimitHelperAccess)?
    @ObservationIgnored private let read: Reader
    /// Bumped by every `setEnabled` so a `refresh()` whose read started before a change
    /// (even one that already finished) does not overwrite the helper's newer read-back.
    @ObservationIgnored private var changeGeneration = 0

    init(helper: any ChargeLimitHelperAccess, read: @escaping Reader = ChargeLimitController.readFromSMC) {
        self.helper = helper
        self.read = read
    }

    // MARK: - Actions

    /// Re-reads `CHWA` (unprivileged) and the helper install status. With
    /// `ifOlderThan`, skips the read when the last one is more recent.
    public func refresh(ifOlderThan maxAge: TimeInterval? = nil) async {
        helper?.refreshHelperStatus()
        isHelperUsable = helper?.isHelperUsable ?? false
        if let maxAge, let lastRefresh, Date().timeIntervalSince(lastRefresh) < maxAge,
           reading != .unknown {
            return
        }
        let generation = changeGeneration
        let value = await read()
        // A change that started (or even finished) meanwhile already published, or will
        // publish, the helper's newer read-back.
        guard !isBusy, generation == changeGeneration else { return }
        reading = value
        lastRefresh = Date()
    }

    /// Turns the charge limit on (`CHWA` = 1, hold at 80 %) or off (`CHWA` = 0).
    /// Explicit user action. Records and rethrows failures (`lastError`); when the
    /// SMC turns out not to have the key, `reading` becomes `.unsupported`.
    public func setEnabled(_ enabled: Bool) async throws {
        guard !isBusy else { return }
        if case .unsupported = reading {
            let error = FanControlError.keyNotFound(ChargeLimitPolicy.key.name)
            lastError = error
            throw error
        }
        guard let helper else { return }
        isBusy = true
        changeGeneration &+= 1
        defer {
            isBusy = false
            helper.refreshHelperStatus()
            isHelperUsable = helper.isHelperUsable
        }
        do {
            try await helper.prepareHelper()
            let value = try await helper.setChargeLimitEnabled(enabled)
            reading = Self.reading(fromReadBack: value)
            lastRefresh = Date()
            lastError = nil
        } catch {
            let mapped = FanControlPoller.fanControlError(from: error)
            if case .helperRejected(let code, let message) = mapped,
               code == FanControlHelperErrorCode.invalidKey.rawValue {
                reading = .unsupported(message)
            }
            lastError = mapped
            throw mapped
        }
    }

    /// Clears `lastError`.
    public func clearError() {
        lastError = nil
    }

    // MARK: - Mapping (static, tested)

    /// The helper's read-back value as a reading.
    nonisolated static func reading(fromReadBack value: Int) -> ChargeLimitReading {
        switch value {
        case 1: return .on
        case 0: return .off
        default: return .unreadable("the helper could not read CHWA back")
        }
    }

    /// Classifies `CHWA` on `reader` (read-only): absent or unexpected layout →
    /// `.unsupported`, value 0/1 → `.off` / `.on`, anything else → `.unreadable`.
    nonisolated static func classify(_ reader: SMCReader) -> ChargeLimitReading {
        let key = ChargeLimitPolicy.key
        let info: SMCKeyInfo
        do {
            info = try reader.keyInfo(key)
        } catch FanControlError.keyNotFound {
            return .unsupported("This Mac's SMC has no \(key.name) key.")
        } catch {
            return .unreadable("Reading \(key.name) failed: \(error)")
        }
        if let rejection = ChargeLimitPolicy.validateKeyInfo(info) {
            return .unsupported(rejection.message)
        }
        do {
            let bytes = try reader.readBytes(key)
            switch ChargeLimitPolicy.decode(bytes) {
            case true?: return .on
            case false?: return .off
            case nil: return .unreadable("\(key.name) holds an unexpected value (\(bytes.map { String($0) }.joined(separator: ","))).")
            }
        } catch {
            return .unreadable("Reading \(key.name) failed: \(error)")
        }
    }

    /// Production reader: a temporary AppleSMC connection on a background task.
    nonisolated static let readFromSMC: Reader = {
        await Task.detached(priority: .utility) { () -> ChargeLimitReading in
            guard FanControlPlatform.isSupported else {
                return .unsupported("The charge limit requires a Mac with Apple silicon (\(FanControlPlatform.unsupportedPlatformDetail)).")
            }
            do {
                let client = try SMCClient()
                defer { client.close() }
                return classify(client)
            } catch {
                return .unreadable("Cannot open the SMC: \(error)")
            }
        }.value
    }

    /// User-facing text for a `setEnabled(_:)` failure.
    public nonisolated static func message(for error: FanControlError) -> String {
        switch error {
        case .keyNotFound:
            return "This Mac does not support limiting charging to 80 %."
        case .helperRejected(let code, let message):
            switch FanControlHelperErrorCode(rawValue: code) {
            case .invalidKey?:
                return "This Mac does not support limiting charging to 80 %."
            case .badRequest?:
                return "The helper refused to change the charge limit: \(message)"
            case .smcError?, .smcUnavailable?:
                return "The SMC did not accept the change: \(message)"
            default:
                return error.localizedDescription
            }
        case .helperNotInstalled, .helperConnectionFailed, .helperConnectionRejected:
            return "The fan control helper is needed to change the charge limit. \(error.localizedDescription)"
        default:
            return error.localizedDescription
        }
    }
}

// MARK: - HelperCoordinator

extension HelperCoordinator: ChargeLimitHelperAccess {
    var isHelperUsable: Bool {
        if case .rejected = helperConnectionState { return false }
        switch helperStatus {
        case .enabled, .installedManually: return true
        default: return false
        }
    }

    func refreshHelperStatus() {
        refreshStatus()
    }

    func setChargeLimitEnabled(_ enabled: Bool) async throws -> Int {
        try await client.setChargeLimitEnabled(enabled)
    }
}
#endif
