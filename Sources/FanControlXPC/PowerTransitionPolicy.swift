import Foundation
import FanControlCore

/// Platform-neutral sleep/wake rules of FanControlHelper (pure planner; the IOKit
/// power-notification glue lives in the helper executable, `PowerObserver`).
///
/// Hardware finding (Mac14,9 / macOS 26, `docs/verification/first-write-2026-10-20.md`
/// テスト 4): across a sleep the SMC resets `F<n>Tg` to 0 but keeps `F<n>Md` = 1, on
/// every fan (even one that was automatic before sleep). Right after wake the fans
/// are therefore "manual, target 0" = stopped until somebody writes. The helper is
/// the safety authority, so it does not rely on the app's wake notification:
///
/// - **Will sleep** (`sleepHandBack`): every fan the open session has forced is
///   handed back to the SMC for the sleep (`F<n>Md` = 0). `F<n>Tg` is not written. The session's intent (the client's last
///   successful writes) is kept, so it can be re-applied on wake.
/// - **Has powered on** (`wakeRecovery`), tried at `wakeRetryDelays` (the SMC may
///   reject writes right at wake); each attempt re-reads the fans, so it is idempotent:
///   - a remembered fan (forced by the session, with a remembered target) that is
///     not in manual mode gets its mode key and then its target re-written; one that
///     is in manual mode with a target off by more than `targetToleranceRPM` gets
///     its target re-written;
///   - any other fan found in manual mode (e.g. `F<n>Md` = 1 with no remembered
///     target, as the SMC woke Fan 2) is handed back to the SMC (`F<n>Md` = 0).
/// - **Wake without a session**: `manualFans` lists fans left in manual mode; the
///   helper only logs a warning (another tool may own them).
///
/// Apple Silicon only: the Intel `FS! ` bitmask is neither read nor written
/// (removed 2026-10-20).
public enum PowerTransitionPolicy {

    /// Delays (seconds after `kIOMessageSystemHasPoweredOn`) of the wake recovery
    /// attempts. Bounded: no attempt is scheduled beyond the last one.
    public static let wakeRetryDelays: [TimeInterval] = [0, 1, 3]

    /// A manual fan whose `F<n>Tg` differs from the remembered target by more than
    /// this (RPM) gets its target re-written on wake.
    public static let targetToleranceRPM: Double = 5

    /// One planned SMC write.
    public struct Write: Equatable, Sendable, CustomStringConvertible {
        public var key: SMCKey
        public var bytes: [UInt8]

        public init(key: SMCKey, bytes: [UInt8]) {
            self.key = key
            self.bytes = bytes
        }

        public var description: String {
            "\(key.name)=\(bytes.map { String(format: "%02x", $0) }.joined())"
        }
    }

    /// A fan the session currently forces, derived from the client's last successful writes.
    public struct RememberedFan: Equatable, Sendable {
        public enum Control: Equatable, Sendable {
            /// `F<n>Md`; `onBytes` is the last (non-zero) payload written.
            case modeKey(onBytes: [UInt8])
            /// Only `F<n>Tg` was written (no `F<n>Md` in this session; never
            /// produced by `FanWriteStrategy`, kept so such a target is still re-applied).
            case targetOnly
        }

        public var fan: Int
        public var control: Control
        /// Last `F<n>Tg` payload written by the client (`nil`: none, or not decodable).
        public var targetBytes: [UInt8]?
        /// `targetBytes` decoded (RPM).
        public var targetRPM: Double?

        public init(fan: Int, control: Control, targetBytes: [UInt8]?, targetRPM: Double?) {
            self.fan = fan
            self.control = control
            self.targetBytes = targetBytes
            self.targetRPM = targetRPM
        }

        /// A mode-controlled fan can only be re-applied with a known target.
        var hasTarget: Bool { targetBytes != nil && targetRPM != nil }
    }

    /// Fan state read from the SMC (see `snapshot(using:fanCount:)`).
    public struct FanState: Equatable, Sendable {
        public var fan: Int
        /// Raw `F<n>Md` (`nil`: key absent or unreadable).
        public var modeBytes: [UInt8]?
        /// `F<n>Tg` in RPM (`nil`: unreadable).
        public var targetRPM: Double?

        public init(fan: Int, modeBytes: [UInt8]?, targetRPM: Double?) {
            self.fan = fan
            self.modeBytes = modeBytes
            self.targetRPM = targetRPM
        }

        /// `F<n>Md` exists and is non-zero.
        public var isModeOn: Bool { modeBytes?.contains { $0 != 0 } ?? false }
    }

    public struct Snapshot: Equatable, Sendable {
        public var fans: [FanState]

        public init(fans: [FanState]) {
            self.fans = fans
        }

        func state(of fan: Int) -> FanState? { fans.first { $0.fan == fan } }
    }

    // MARK: - Session intent

    /// The fans the session forces, from the client's last successful write per key
    /// (`lastWritten`; the helper's own power writes are not recorded there).
    public static func rememberedFans(lastWritten: [SMCKey: [UInt8]],
                                      keyInfo: (SMCKey) -> SMCKeyInfo?) -> [RememberedFan] {
        var controls: [Int: RememberedFan.Control] = [:]
        var targets: [Int: [UInt8]] = [:]
        for (key, bytes) in lastWritten {
            if let (fan, suffix) = HelperWritePolicy.fanKeyParts(key) {
                switch suffix {
                case "Md" where bytes.contains { $0 != 0 }:
                    controls[fan] = .modeKey(onBytes: bytes)
                case "Tg":
                    targets[fan] = bytes
                default:
                    break
                }
            }
        }
        // Fans with only a target written (no mode key in this session). A fan whose
        // last `F<n>Md` write was 0 was handed back by the client and is not forced.
        for fan in targets.keys where controls[fan] == nil
            && lastWritten[.fanMode(fan)] == nil {
            controls[fan] = .targetOnly
        }
        return controls.keys.sorted().map { fan in
            let bytes = targets[fan]
            let rpm = bytes.flatMap { b in keyInfo(.fanTarget(fan)).flatMap { SMCCodec.decode(b, as: $0.dataType)?.doubleValue } }
            return RememberedFan(fan: fan, control: controls[fan]!, targetBytes: rpm == nil ? nil : bytes,
                                 targetRPM: rpm.flatMap { $0.isFinite ? $0 : nil })
        }
    }

    // MARK: - Snapshot

    /// Reads `F<n>Md` / `F<n>Tg` for fans `0..<fanCount`. Never throws:
    /// unreadable values are `nil`.
    public static func snapshot(using reader: SMCReader, fanCount: Int) -> Snapshot {
        var fans: [FanState] = []
        for fan in 0..<min(max(fanCount, 0), 10) {
            let mode = reader.exists(.fanMode(fan)) ? (try? reader.readBytes(.fanMode(fan))) : nil
            let target = (try? reader.readNumber(.fanTarget(fan))).flatMap { $0.isFinite ? $0 : nil }
            fans.append(FanState(fan: fan, modeBytes: mode, targetRPM: target))
        }
        return Snapshot(fans: fans)
    }

    // MARK: - Plans

    /// Writes that hand every remembered mode-controlled fan back to the SMC before
    /// sleep: `F<n>Md` = 0 (ascending fan index). No `F<n>Tg` writes.
    public static func sleepHandBack(remembered: [RememberedFan], snapshot: Snapshot) -> [Write] {
        var writes: [Write] = []
        for fan in remembered.sorted(by: { $0.fan < $1.fan }) {
            if case .modeKey(let onBytes) = fan.control {
                let size = snapshot.state(of: fan.fan)?.modeBytes?.count ?? onBytes.count
                writes.append(Write(key: .fanMode(fan.fan), bytes: [UInt8](repeating: 0, count: max(size, 1))))
            }
        }
        return writes
    }

    /// Writes for one wake recovery attempt (empty when the fans already match).
    /// Order: `F<n>Md` writes (ascending), then `F<n>Tg` writes (ascending), so a
    /// target is never written before its fan is forced.
    public static func wakeRecovery(remembered: [RememberedFan], snapshot: Snapshot) -> [Write] {
        var modeWrites: [Write] = []
        var targetWrites: [Write] = []
        let byFan = Dictionary(remembered.map { ($0.fan, $0) }, uniquingKeysWith: { first, _ in first })
        let fanIndices = Set(snapshot.fans.map(\.fan)).union(byFan.keys).sorted()

        for index in fanIndices {
            let state = snapshot.state(of: index)
            if let fan = byFan[index], fan.hasTarget, let targetBytes = fan.targetBytes, let rpm = fan.targetRPM {
                let targetOff = state?.targetRPM.map { abs($0 - rpm) > targetToleranceRPM } ?? true
                switch fan.control {
                case .modeKey(let onBytes):
                    let modeOn = state?.isModeOn ?? false
                    if !modeOn { modeWrites.append(Write(key: .fanMode(index), bytes: onBytes)) }
                    if !modeOn || targetOff { targetWrites.append(Write(key: .fanTarget(index), bytes: targetBytes)) }
                case .targetOnly:
                    if targetOff { targetWrites.append(Write(key: .fanTarget(index), bytes: targetBytes)) }
                }
                continue
            }
            // Not (re-)appliable: a manual fan here has nothing valid to run at -> SMC.
            if let state, state.isModeOn, let mode = state.modeBytes {
                modeWrites.append(Write(key: .fanMode(index), bytes: [UInt8](repeating: 0, count: mode.count)))
            }
        }
        return modeWrites + targetWrites
    }

    /// Fans found in manual mode (`F<n>Md` ≠ 0), ascending.
    public static func manualFans(_ snapshot: Snapshot) -> [Int] {
        snapshot.fans.filter(\.isModeOn).map(\.fan).sorted()
    }
}
