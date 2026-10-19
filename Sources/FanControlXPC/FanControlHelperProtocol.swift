#if os(macOS)
import Foundation

/// XPC interface vended by FanControlHelper.
///
/// Every reply carries an `Int` return code (`FanControlHelperErrorCode.rawValue`)
/// and a human-readable message. Only a single client (the session owner) may write.
@objc public protocol FanControlHelperProtocol {
    /// Replies with (`FanControlHelperConstants.protocolVersion`, build string).
    func version(reply: @escaping (Int, String) -> Void)
    /// Opens the exclusive write session for the calling process.
    func openSession(reply: @escaping (Int, String) -> Void)
    /// Writes raw big-endian bytes to an allowlisted SMC key. Requires an open session.
    func writeKey(_ key: String, bytes: Data, reply: @escaping (Int, String) -> Void)
    /// Closes the write session owned by the calling process.
    func closeSession(reply: @escaping (Int, String) -> Void)
    /// Replies with (rc, dataSize, dataType FourCC, attributes, message).
    func readKeyInfo(_ key: String, reply: @escaping (Int, Int, UInt32, UInt8, String) -> Void)
}

/// Return codes used in helper replies.
public enum FanControlHelperErrorCode: Int, Sendable {
    case ok = 0
    case notSessionOwner = 1
    case sessionNotOpen = 2
    case invalidKey = 3
    case keyNotAllowed = 4
    case smcUnavailable = 5
    case smcError = 6
    case badRequest = 7
}

/// Builds the `NSXPCInterface` used on both sides of the connection.
public func makeHelperInterface() -> NSXPCInterface {
    NSXPCInterface(with: FanControlHelperProtocol.self)
}
#endif
