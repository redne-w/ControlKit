import ControlKitRuntime
import ControlKitWire
import Darwin
import Foundation

enum SupervisorEndpoint {
    static func directory() throws -> PrivateDirectory {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .resolvingSymlinksInPath().appendingPathComponent("ControlKit-supervisor-v1")
        return try PrivateDirectory(root)
    }
}

package final class LocalListener {
    private let directory: PrivateDirectory
    private var lock: FileLock?
    private let descriptor: Int32
    let socketURL: URL

    package init(directory supplied: PrivateDirectory? = nil) throws {
        directory = try supplied ?? SupervisorEndpoint.directory()
        lock = try FileLock(directory: directory, name: "supervisor.lock")
        socketURL = directory.url.appendingPathComponent("control.sock")
        try Self.removeStale(socketURL)
        descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw WireFailure.socketFailure }
        do {
            try Self.configure(descriptor)
            var address = try Self.address(socketURL.path)
            let status = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard status == 0, chmod(socketURL.path, 0o600) == 0, listen(descriptor, 32) == 0 else {
                throw WireFailure.socketFailure
            }
        } catch {
            close(descriptor)
            throw error
        }
    }

    deinit {
        close(descriptor)
        lock = nil
        unlink(socketURL.path)
    }

    package func accept(milliseconds: Int32 = 100) throws -> WireSocket? {
        var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let result = poll(&item, 1, milliseconds)
        if result == 0 { return nil }
        guard result > 0, item.revents & Int16(POLLIN) != 0 else {
            throw WireFailure.socketFailure
        }
        let client = Darwin.accept(descriptor, nil, nil)
        guard client >= 0 else { throw WireFailure.socketFailure }
        var user: uid_t = 0
        var group: gid_t = 0
        guard getpeereid(client, &user, &group) == 0, user == getuid() else {
            close(client)
            throw WireFailure.authenticationFailed
        }
        return try WireSocket(owning: client)
    }

    package static func connect(directory supplied: PrivateDirectory? = nil) throws -> WireSocket {
        let directory = try supplied ?? SupervisorEndpoint.directory()
        let path = directory.url.appendingPathComponent("control.sock").path
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw WireFailure.socketFailure }
        do {
            try configure(descriptor)
            var address = try self.address(path)
            let status = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard status == 0 || errno == EINPROGRESS else { throw WireFailure.socketFailure }
            let socket = try WireSocket(owning: descriptor)
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            try socket.wait(POLLOUT, until: deadline, progress: {})
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &size) == 0,
                error == 0
            else {
                throw WireFailure.socketFailure
            }
            return socket
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func configure(_ descriptor: Int32) throws {
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
            fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0
        else { throw WireFailure.socketFailure }
    }

    private static func address(_ path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8) + [0]
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count <= capacity else { throw WireFailure.socketFailure }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes)
        }
        return address
    }

    private static func removeStale(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else { throw WireFailure.socketFailure }
            return
        }
        guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK,
            unlink(url.path) == 0
        else { throw WireFailure.socketFailure }
    }
}
