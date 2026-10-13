import Darwin
import Foundation
import Testing

@testable import ControlKitRuntime

struct PrivateDirectoryTests {
    @Test func privateModesNoClobberAndSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try PrivateDirectory(root)
        try directory.write("data", data: Data("private".utf8))
        #expect(throws: RuntimeFailure.self) { try directory.write("data", data: Data()) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"),
            withDestinationURL: root.appendingPathComponent("data"))
        #expect(throws: RuntimeFailure.self) {
            _ = try directory.openFile("link", flags: O_RDONLY)
        }
        #expect(throws: RuntimeFailure.self) { try directory.write("../escape", data: Data()) }
        #expect(chmod(root.path, 0o755) == 0)
        #expect(throws: RuntimeFailure.self) { _ = try PrivateDirectory(root) }
    }

    @Test func claimSurvivesOwnerLossAndCompletionClearsOnlyRecord() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try PrivateDirectory(root)
        let device = UUID()
        var claim: DeviceClaim? = try DeviceClaim(
            directory: directory, device: device, operation: "test")
        #expect(throws: RuntimeFailure.self) {
            _ = try DeviceClaim(directory: directory, device: device, operation: "conflict")
        }
        try #require(claim).complete()
        claim = nil
        do {
            let abandoned = try DeviceClaim(
                directory: directory, device: device, operation: "abandoned")
            try abandoned.begin()
        }
        #expect(throws: RuntimeFailure.self) {
            _ = try DeviceClaim(directory: directory, device: device, operation: "never replay")
        }
        #expect(try directory.entries().count == 2)
    }
}
