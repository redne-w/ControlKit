import Darwin
import Foundation
import Testing

@testable import ControlKitProbeCore

struct ConnectionTests {
    private func withFile(
        contents: Data, permissions: Int = 0o600, body: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("controlkit-connection-test-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("connection.json")
        try contents.write(to: file, options: .withoutOverwriting)
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions], ofItemAtPath: file.path)
        try body(file)
    }

    @Test func loadsPrivateConnection() throws {
        let token = String(repeating: "a", count: 32)
        let data = Data(#"{"port":54321,"token":"\#(token)"}"#.utf8)
        try withFile(contents: data) { file in
            let connection = try ProbeConnection.load(from: file.path)
            #expect(connection.port == 54321)
            #expect(connection.token == token)
        }
    }

    @Test func rejectsSharedPermissionsAndSymlinks() throws {
        let data = Data(#"{"port":54321,"token":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#.utf8)
        try withFile(contents: data, permissions: 0o644) { file in
            #expect(throws: ProbeFailure.self) { try ProbeConnection.load(from: file.path) }
        }
        try withFile(contents: data) { file in
            let link = file.deletingLastPathComponent().appendingPathComponent("link.json")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
            #expect(throws: ProbeFailure.self) { try ProbeConnection.load(from: link.path) }
        }
    }

    @Test(arguments: [
        Data(), Data(repeating: 65, count: 1_025), Data("not-json".utf8),
        Data(#"{"port":0,"token":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#.utf8),
        Data(#"{"port":54321,"token":"short"}"#.utf8),
    ])
    func rejectsInvalidConnection(contents: Data) throws {
        try withFile(contents: contents) { file in
            #expect(throws: ProbeFailure.self) { try ProbeConnection.load(from: file.path) }
        }
    }
}
