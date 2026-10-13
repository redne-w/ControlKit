import ControlKitProcess
import Foundation
import Testing

@testable import ControlKitRuntime

struct DiagnosticReportTests {
    @Test func archiveContainsSanitizedLogsCapturesAndRecentCrashes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = root.appendingPathComponent("logs")
        let crashes = root.appendingPathComponent("crashes")
        let output = root.appendingPathComponent("output")
        for url in [crashes, output] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        DiagnosticLog.record("before.report", ["note": "hello"], in: logs)
        let result = try OwnedProcess(
            ProcessCommand(
                executable: "/bin/sh", arguments: ["-c", "echo 'error: broken'; exit 1"],
                environment: [:], directory: "/", timeoutMilliseconds: 10_000)
        ).wait()
        DiagnosticLog.toolFailure(label: "simctl", arguments: ["simctl"], result: result, in: logs)
        for day in 1...7 {
            try Data("crash \(day) \(NSHomeDirectory())/x".utf8).write(
                to: crashes.appendingPathComponent("ControlKit-2026-10-0\(day)-120000.ips"))
        }
        try Data("other".utf8).write(to: crashes.appendingPathComponent("Other-2026.ips"))
        let archive = try DiagnosticReport.create(
            DiagnosticReport.Inputs(
                executable: URL(fileURLWithPath: "/usr/bin/true"), workingDirectory: root,
                outputDirectory: output, logDirectory: logs, crashDirectory: crashes),
            includeCommands: false)
        #expect(archive.pathExtension == "zip")
        let extracted = root.appendingPathComponent("extracted")
        let unzip = try OwnedProcess(
            ProcessCommand(
                executable: "/usr/bin/ditto",
                arguments: ["-x", "-k", archive.path, extracted.path],
                environment: [:], directory: "/", timeoutMilliseconds: 30_000)
        ).wait()
        #expect(unzip.succeeded)
        let top = try #require(
            try FileManager.default.contentsOfDirectory(atPath: extracted.path).first)
        let report = extracted.appendingPathComponent(top)
        let files = try #require(FileManager.default.subpaths(atPath: report.path))
        #expect(files.contains("summary.txt"))
        #expect(files.contains("logs/controlkit.log"))
        #expect(files.contains { $0.hasPrefix("logs/tool-failures/") && $0.hasSuffix(".log") })
        let crashFiles = files.filter { $0.hasPrefix("crash-reports/") }.sorted()
        #expect(crashFiles.count == DiagnosticReport.maximumCrashReports)
        #expect(crashFiles.last == "crash-reports/ControlKit-2026-10-07-120000.ips")
        let crash = try String(
            contentsOf: report.appendingPathComponent(crashFiles.last!), encoding: .utf8)
        #expect(crash == "crash 7 ~/x")
        let log = try String(
            contentsOf: report.appendingPathComponent("logs/controlkit.log"), encoding: .utf8)
        #expect(log.contains("before.report"))
        #expect(log.contains("tool.failed"))
    }
}
