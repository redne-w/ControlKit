import Foundation
import Testing

@testable import ControlKitRuntime

struct AppLifecycleTests {
    @Test func rejectsMissingAndSymlinkAppsBeforeToolExecution() throws {
        let lifecycle = try AppLifecycle(tools: AppleTools())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        #expect(throws: RuntimeFailure.self) {
            _ = try lifecycle.inspect(path: root.appendingPathComponent("Missing.app").path)
        }
        let real = root.appendingPathComponent("Real.app")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        let alias = root.appendingPathComponent("Alias.app")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        #expect(throws: RuntimeFailure.self) {
            _ = try lifecycle.inspect(path: alias.path)
        }
    }

    @Test func appleToolErrorsIdentifyOnlyTheFixedPhase() throws {
        let tools = try AppleTools()
        do {
            _ = try tools.run(["false"], label: "test_phase")
            Issue.record("Expected the tool to fail.")
        } catch let failure as RuntimeFailure {
            #expect(failure.code == "tool_failed")
            #expect(failure.message.hasPrefix("test_phase:"))
        }
    }
}
