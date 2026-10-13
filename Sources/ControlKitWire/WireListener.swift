import Darwin
import Foundation

public final class WireListener {
    private let socket: WireSocket
    public let port: UInt16

    public init() throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw WireFailure.socketFailure }
        socket = try WireSocket(owning: descriptor)
        var address = Self.address(port: 0)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &size)
            }
        }
        guard bound == 0, named == 0, listen(descriptor, 8) == 0 else {
            throw WireFailure.socketFailure
        }
        port = UInt16(bigEndian: address.sin_port)
    }

    public func close() { socket.close() }

    public func accept(
        until deadline: ContinuousClock.Instant, progress: () throws -> Void = {}
    ) throws -> WireSocket {
        while true {
            try socket.wait(POLLIN, until: deadline, progress: progress)
            let accepted = Darwin.accept(socket.descriptor, nil, nil)
            if accepted < 0, errno == EAGAIN || errno == EINTR { continue }
            guard accepted >= 0 else { throw WireFailure.socketFailure }
            return try WireSocket(owning: accepted)
        }
    }

    public static func connect(port: UInt16, until deadline: ContinuousClock.Instant) throws
        -> WireSocket
    {
        guard port > 0 else { throw WireFailure.socketFailure }
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw WireFailure.socketFailure }
        let socket = try WireSocket(owning: descriptor)
        var address = address(port: port)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 || errno == EINPROGRESS else { throw WireFailure.socketFailure }
        try socket.wait(POLLOUT, until: deadline, progress: {})
        var error: Int32 = 0
        var size: socklen_t = 4
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
            throw WireFailure.socketFailure
        }
        return socket
    }

    private static func address(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = port.bigEndian
        return address
    }
}
