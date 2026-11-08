import Foundation

/// Why an SSH operation failed. Every error of the SSH library is mapped to one of these at
/// SSHKit's boundary: no library type reaches the app.
public enum SSHError: Error, Equatable, Sendable {
    /// The host could not be reached: refused, unresolvable, no route.
    case unreachable
    /// The server did not answer within the timeout.
    case timedOut
    /// The connection ended: the server closed it, the network dropped, or keepalives went unanswered.
    case connectionClosed
    /// The host key validator refused this key; nothing was sent to the server after key exchange.
    case hostKeyRejected(SSHHostKey)
    /// The server accepted none of the credentials.
    case authFailed
    /// The server refused to open a channel or a request on it (pty, shell, forward); the reason
    /// says which.
    case channelFailed(String)
    /// The server has no SFTP subsystem.
    case sftpUnavailable
    /// A local port forward could not listen on this port.
    case portInUse(UInt16)
    /// Any other failure the server or the protocol reported, described for a log.
    case remote(String)
}
