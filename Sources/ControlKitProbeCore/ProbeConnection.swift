import Darwin
import Foundation

/// Private development rendezvous data, never the production session or authentication format.
public struct ProbeConnection: Codable, Sendable {
    public let port: UInt16
    public let token: String

    public static func load(from path: String) throws -> ProbeConnection {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw ProbeFailure(
                "invalid_connection_file", "Cannot open the private connection file.")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0,
            attributes.st_mode & S_IFMT == S_IFREG,
            attributes.st_uid == geteuid(),
            attributes.st_mode & 0o077 == 0,
            attributes.st_size > 0, attributes.st_size <= 1_024
        else {
            throw ProbeFailure(
                "invalid_connection_file", "Expected a small, owner-only regular connection file.")
        }
        guard let data = try handle.read(upToCount: 1_025), data.count <= 1_024 else {
            throw ProbeFailure("invalid_connection_file", "Connection file exceeds its byte limit.")
        }
        let connection: ProbeConnection
        do {
            connection = try JSONDecoder().decode(ProbeConnection.self, from: data)
        } catch {
            // Decoder diagnostics must not echo credential-bearing input.
            throw ProbeFailure("invalid_connection_file", "Cannot decode connection information.")
        }
        guard connection.port > 0, (32...128).contains(connection.token.utf8.count) else {
            throw ProbeFailure("invalid_connection_file", "Invalid connection information.")
        }
        return connection
    }
}
