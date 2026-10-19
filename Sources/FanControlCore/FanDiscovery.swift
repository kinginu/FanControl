import Foundation

/// Discovers fans and reads their state through an `SMCReader`.
///
/// Works for both Intel-era SMCs (`fpe2` fan keys) and Apple Silicon
/// (`flt ` fan keys) because all numeric reads go through `readNumber`.
public enum FanDiscovery {

    /// Reads `FNum` and builds a `FanDevice` for each fan whose `F<i>Mn` and
    /// `F<i>Mx` can be read. Fans whose min/max read fails are skipped.
    /// Throws only if `FNum` itself cannot be read.
    public static func discoverFans(using reader: SMCReader) throws -> [FanDevice] {
        let rawCount = try reader.readNumber(.fanCount)
        guard rawCount.isFinite, rawCount >= 1 else { return [] }
        let count = Int(min(rawCount, 10))
        var fans: [FanDevice] = []
        for i in 0..<count {
            guard let minRPM = try? reader.readNumber(.fanMin(i)),
                  let maxRPM = try? reader.readNumber(.fanMax(i)),
                  finite(minRPM) != nil, finite(maxRPM) != nil else { continue }
            fans.append(FanDevice(id: i,
                                  name: fanName(index: i, using: reader),
                                  minRPM: Int(minRPM.rounded()),
                                  maxRPM: Int(maxRPM.rounded())))
        }
        return fans
    }

    /// Measured speeds (`F<i>Ac`) per fan id. Failed reads are omitted.
    public static func readCurrentRPMs(fans: [FanDevice], using reader: SMCReader) -> [Int: Int] {
        readRPMs(fans: fans, using: reader, key: SMCKey.fanActual)
    }

    /// Target speeds (`F<i>Tg`) per fan id. Failed reads are omitted.
    public static func readTargetRPMs(fans: [FanDevice], using reader: SMCReader) -> [Int: Int] {
        readRPMs(fans: fans, using: reader, key: SMCKey.fanTarget)
    }

    /// Best-effort detection of each fan's current control mode:
    /// 1. If `F<i>Md` exists: non-zero → manual, zero → automatic.
    /// 2. Otherwise, if `FS! ` exists: bit *i* set → manual.
    /// 3. Otherwise `.automatic`.
    ///
    /// Manual fans are reported as `.constant(rpm:)` using the current target
    /// (falling back to the measured speed, then the fan's minimum).
    public static func fanControlModes(fans: [FanDevice], using reader: SMCReader) -> [Int: FanControlMode] {
        let forceBits: UInt64? = reader.exists(.forceBits)
            ? (try? reader.readNumber(.forceBits)).flatMap { $0.isFinite ? UInt64(min(max(0, $0), 65535)) : nil }
            : nil
        var modes: [Int: FanControlMode] = [:]
        for fan in fans {
            let manual: Bool
            if reader.exists(.fanMode(fan.id)) {
                manual = ((try? reader.readNumber(.fanMode(fan.id))) ?? 0) != 0
            } else if let bits = forceBits {
                manual = bits & (UInt64(1) << UInt64(fan.id)) != 0
            } else {
                manual = false
            }
            if manual {
                let rpm = finite(try? reader.readNumber(.fanTarget(fan.id)))
                    ?? finite(try? reader.readNumber(.fanActual(fan.id)))
                    ?? Double(fan.minRPM)
                modes[fan.id] = .constant(rpm: Int(rpm.rounded()))
            } else {
                modes[fan.id] = .automatic
            }
        }
        return modes
    }

    // MARK: - Helpers

    /// Extracts the fan name from `F<i>ID`. The typical record is 16 bytes with
    /// an ASCII name starting at byte 4 (e.g. "Exhaust", "Left Side"); the
    /// printable ASCII run from byte 4 is taken and trimmed. Falls back to
    /// "Fan N" (1-based).
    static func fanName(index: Int, using reader: SMCReader) -> String {
        let fallback = "Fan \(index + 1)"
        guard let bytes = try? reader.readBytes(.fanID(index)), bytes.count > 4 else { return fallback }
        let run = bytes[4...].prefix { (0x20...0x7E).contains($0) }
        let name = String(decoding: run, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? fallback : name
    }

    private static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite, abs(value) < 1_000_000 else { return nil }
        return value
    }

    private static func readRPMs(fans: [FanDevice], using reader: SMCReader,
                                 key: (Int) -> SMCKey) -> [Int: Int] {
        var result: [Int: Int] = [:]
        for fan in fans {
            if let value = finite(try? reader.readNumber(key(fan.id))) {
                result[fan.id] = Int(value.rounded())
            }
        }
        return result
    }
}
