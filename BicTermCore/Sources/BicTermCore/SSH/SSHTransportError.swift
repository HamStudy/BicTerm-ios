import Foundation

/// T11 unified the error vocabulary: the SSH layer and the Sessions layer
/// share ``TransportError`` (defined in `Transport/`). The case set is
/// unchanged from the original T7 enum, so every existing catch site,
/// typed-throws signature and test assertion keeps working.
public typealias SSHTransportError = TransportError
