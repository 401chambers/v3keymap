import Foundation

/// One request/reply exchange with the keyboard's VIA raw HID channel.
/// Requests are up to 32 bytes (zero-padded by the transport); replies are exactly 32 bytes.
public protocol HIDTransport: Sendable {
    func exchange(_ request: [UInt8]) async throws -> [UInt8]
}

public enum ViaError: Error, Equatable {
    case timeout
    case shortReply
    case unsupported(command: UInt8)
    case wrongDevice(String)
    case disconnected
    case verifyMismatch([String])
    case forbiddenCommand(UInt8)
    case invalid(String)
    case permissionDenied
    /// The keyboard understood the request but refused it (non-zero extra-commands status byte).
    case rejected(String)
}
