import ControlKitProcess
import Darwin
import Foundation
import Testing

@testable import ControlKitRuntime

struct DiagnosticLogTests {
    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func lines(_ url: URL) throws -> [[String: Any]] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    @Test func recordsOwnerOnlySanitizedJSONLines() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = NSHomeDirectory()
        DiagnosticLog.record(
            "test.event",
            ["path": "\(home)/Project/App.swift", "header": "Authorization: Bearer abc.def"],
            in: root)
        DiagnosticLog.failure("test.failure", RuntimeFailure("code", "message"), in: root)
        let log = root.appendingPathComponent(DiagnosticLog.logName)
        let entries = try lines(log)
        #expect(entries.count == 2)
        let fields = try #require(entries[0]["fields"] as? [String: String])
        #expect(fields["path"] == "~/Project/App.swift")
        #expect(fields["header"]?.contains("abc.def") == false)
        #expect(entries[0]["event"] as? String == "test.event")
        #expect(entries[0]["version"] as? String == ControlKitVersion.description)
        #expect((entries[1]["fields"] as? [String: String])?["error"] == "code: message")
        var info = stat()
        #expect(stat(log.path, &info) == 0 && info.st_mode & 0o777 == 0o600)
        #expect(stat(root.path, &info) == 0 && info.st_mode & 0o777 == 0o700)
    }

    @Test func typedTextNeverReachesArguments() {
        let value = DiagnosticLog.sanitize(arguments: [
            "ui", "type", "--text", "hunter2", "--id", "password", "--text=secret2",
        ])
        #expect(value == "ui type --text <redacted> --id password --text=<redacted>")
    }

    @Test func rotationBoundsTheLogToTwoGenerations() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let value = String(repeating: "x", count: DiagnosticLog.maximumValueBytes)
        let perLine = DiagnosticLog.maximumValueBytes + 256
        let count = Int(DiagnosticLog.maximumLogBytes) / perLine * 3
        for index in 0..<count {
            DiagnosticLog.record("fill", ["i": "\(index)", "v": value], in: root)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(names.contains(DiagnosticLog.rotatedLogName))
        for name in [DiagnosticLog.logName, DiagnosticLog.rotatedLogName] {
            let size = try #require(
                try FileManager.default.attributesOfItem(
                    atPath: root.appendingPathComponent(name).path)[.size] as? Int)
            #expect(size <= Int(DiagnosticLog.maximumLogBytes) + perLine)
        }
        let newest = try lines(root.appendingPathComponent(DiagnosticLog.logName))
        #expect((newest.last?["fields"] as? [String: String])?["i"] == "\(count - 1)")
    }

    @Test func unusableDirectoryNeverThrowsOrWrites() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        DiagnosticLog.record("ignored", in: root)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func toolFailureKeepsErrorsAndBoundedCaptures() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = """
            echo 'Compiling App.swift'
            echo '/tmp/App.swift:3:5: error: cannot find foo in scope'
            echo '** BUILD FAILED **'
            echo 'token=abc123' >&2
            exit 65
            """
        let result = try OwnedProcess(
            ProcessCommand(
                executable: "/bin/sh", arguments: ["-c", script], environment: [:],
                directory: "/", timeoutMilliseconds: 10_000)
        ).wait()
        let total = DiagnosticLog.maximumFailureCaptures + 3
        for _ in 0..<total {
            DiagnosticLog.toolFailure(
                label: "xcode_build", arguments: ["xcodebuild", "build"], result: result, in: root)
        }
        let entries = try lines(root.appendingPathComponent(DiagnosticLog.logName))
        #expect(entries.count == total)
        let fields = try #require(entries.last?["fields"] as? [String: String])
        #expect(fields["exitCode"] == "65")
        #expect(fields["errors"]?.contains("cannot find foo in scope") == true)
        #expect(fields["errors"]?.contains("BUILD FAILED") == true)
        #expect(fields["stderrTail"] == "token=<redacted>\n")
        let captures = root.appendingPathComponent(DiagnosticLog.failureDirectoryName)
        let names = try FileManager.default.contentsOfDirectory(atPath: captures.path)
        #expect(names.count == DiagnosticLog.maximumFailureCaptures)
        let capture = try #require(fields["capture"])
        let text = try String(
            contentsOf: root.appendingPathComponent(capture), encoding: .utf8)
        #expect(text.contains("Compiling App.swift"))
        #expect(text.contains("label: xcode_build"))
        #expect(!text.contains("abc123"))
    }
}
