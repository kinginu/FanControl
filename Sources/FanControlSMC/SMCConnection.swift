#if os(macOS)
import Foundation
import IOKit
import FanControlCore

/// A user-client connection to the `AppleSMC` IOService.
///
/// Reading does not require privileges; writing does (only the root helper should write).
/// All calls are serialized with a lock, so one instance may be shared across threads.
public final class SMCConnection: @unchecked Sendable {
    private var connection: io_connect_t = 0
    private let lock = NSLock()

    /// Opens the AppleSMC user client. Throws `FanControlError.smcUnavailable` on failure.
    public init() throws {
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSMC"), &iterator)
        guard kr == KERN_SUCCESS else { throw FanControlError.smcUnavailable }
        defer { IOObjectRelease(iterator) }

        let service = IOIteratorNext(iterator)
        guard service != 0 else { throw FanControlError.smcUnavailable }
        defer { IOObjectRelease(service) }

        var conn: io_connect_t = 0
        let openResult = IOServiceOpen(service, mach_task_self_, 0, &conn)
        guard openResult == KERN_SUCCESS, conn != 0 else { throw FanControlError.smcUnavailable }
        connection = conn
    }

    deinit {
        close()
    }

    /// `true` if an AppleSMC service exists on this machine.
    public static func isAvailable() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        IOObjectRelease(service)
        return true
    }

    /// Closes the connection. Further calls throw `smcUnavailable`. Idempotent.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        if connection != 0 {
            IOServiceClose(connection)
            connection = 0
        }
    }

    /// Performs one `kSMCHandleYPCEvent` round trip.
    ///
    /// Throws `readFailed`/`writeFailed` (depending on `input.data8`) with the
    /// `kern_return_t` or the SMC result byte, and `keyNotFound` for result `0x84`.
    func call(_ input: inout SMCParamStruct) throws -> SMCParamStruct {
        lock.lock()
        defer { lock.unlock() }

        let keyName = SMCKey(code: input.key).name
        let isWrite = input.data8 == kSMCWriteKey
        func failure(_ code: Int32) -> FanControlError {
            isWrite ? .writeFailed(key: keyName, code: code) : .readFailed(key: keyName, code: code)
        }

        guard connection != 0 else { throw FanControlError.smcUnavailable }

        var output = SMCParamStruct()
        var outputSize = SMCParamStruct.size
        let kr = IOConnectCallStructMethod(connection,
                                           kSMCHandleYPCEvent,
                                           &input,
                                           SMCParamStruct.size,
                                           &output,
                                           &outputSize)
        guard kr == KERN_SUCCESS else { throw failure(kr) }
        // A short reply would leave `output` partially zero-filled (result 0 = success).
        guard outputSize == SMCParamStruct.size else { throw failure(-1) }

        switch output.result {
        case kSMCSuccess:
            return output
        case kSMCKeyNotFound:
            throw FanControlError.keyNotFound(keyName)
        default:
            throw failure(Int32(output.result))
        }
    }
}
#endif
