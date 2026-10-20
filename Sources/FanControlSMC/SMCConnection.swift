import FanControlCore
#if os(macOS)
import IOKit
import Synchronization
#endif

/// One request/reply exchange with the SMC. `SMCConnection` is the IOKit
/// implementation; tests substitute an in-memory SMC.
///
/// Implementations report transport failures only (by throwing `request.failure(code:)`
/// or `smcUnavailable`) and return the reply as-is: the SMC result byte is interpreted
/// by the caller (`SMCParamStruct.validate(reply:)`).
protocol SMCTransport: Sendable {
    /// Performs one round trip and returns the raw reply.
    func send(_ request: SMCParamStruct) throws -> SMCParamStruct
    /// Releases the transport; later `send` calls throw `smcUnavailable`. Idempotent.
    func close()
}

#if os(macOS)
/// A user-client connection to the `AppleSMC` IOService.
///
/// Reading does not require privileges; writing does (only the root helper should
/// write). Every round trip runs with a `Mutex` held around the connection handle, so
/// one instance may be shared across threads (checked `Sendable`) and `close()` cannot
/// race an in-flight call.
///
/// Only `isAvailable()` is public; clients open connections through `SMCClient`.
public final class SMCConnection: SMCTransport, Sendable {
    /// The user-client handle; 0 once closed. Held for the whole IOKit round trip.
    private let connection: Mutex<io_connect_t>

    /// Opens the AppleSMC user client. Throws `FanControlError.smcUnavailable` if the
    /// service is missing or `IOServiceOpen` fails.
    init() throws {
        // `IOServiceGetMatchingService` consumes the matching dictionary and returns a
        // retained service (or 0).
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw FanControlError.smcUnavailable }
        defer { IOObjectRelease(service) }

        var handle: io_connect_t = 0
        let kr = IOServiceOpen(service, mach_task_self_, 0, &handle)
        guard kr == KERN_SUCCESS, handle != 0 else {
            if handle != 0 { IOServiceClose(handle) }
            throw FanControlError.smcUnavailable
        }
        connection = Mutex(handle)
    }

    deinit {
        close()
    }

    /// `true` if an AppleSMC service exists on this machine (does not open it).
    public static func isAvailable() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        IOObjectRelease(service)
        return true
    }

    /// Closes the connection. Later calls throw `smcUnavailable`. Idempotent; also
    /// run by `deinit`.
    func close() {
        connection.withLock { handle in
            if handle != 0 {
                IOServiceClose(handle)
                handle = 0
            }
        }
    }

    /// Performs one `kSMCHandleYPCEvent` round trip.
    ///
    /// Throws `smcUnavailable` once closed, and `request.failure(code:)` with the
    /// `kern_return_t` if IOKit fails or with `-1` for a short reply. The SMC result
    /// byte is not interpreted here.
    func send(_ request: SMCParamStruct) throws -> SMCParamStruct {
        try connection.withLock { handle in
            guard handle != 0 else { throw FanControlError.smcUnavailable }

            var input = request
            var output = SMCParamStruct()
            var outputSize = SMCParamStruct.size
            let kr = IOConnectCallStructMethod(handle,
                                               kSMCHandleYPCEvent,
                                               &input,
                                               SMCParamStruct.size,
                                               &output,
                                               &outputSize)
            guard kr == KERN_SUCCESS else { throw request.failure(code: kr) }
            // A short reply would leave `output` partially zero-filled (result 0 = success).
            guard outputSize == SMCParamStruct.size else {
                throw request.failure(code: kSMCLocalFailureCode)
            }
            return output
        }
    }
}
#endif
