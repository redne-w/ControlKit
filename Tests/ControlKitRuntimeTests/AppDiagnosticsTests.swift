import Darwin
import Foundation
import Testing

@testable import ControlKitRuntime

@Suite struct AppDiagnosticsTests {
    @Test func resolvesExactBundleAndRejectsMissingBundle() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "dev.example.app",
                "CFBundleExecutable": "Example",
            ],
            format: .binary, options: 0)
        #expect(try AppDiagnostics.executable(plist: data, bundle: "dev.example.app") == "Example")
        #expect(throws: RuntimeFailure.self) {
            try AppDiagnostics.executable(plist: data, bundle: "dev.example")
        }
    }

    @Test func parsesExactProcessAndRedactsBeforeReturning() throws {
        let data = Data(
            """
            [
              {"timestamp":"now","processImagePath":"/Example.app/Example",
               "eventMessage":"token=abc https://x/y?q=1"},
              {"timestamp":"now","process":"Other",
               "eventMessage":"not returned"}
            ]
            """.utf8)
        let values = try AppDiagnostics.parseLogs(data, process: "Example", limit: 10)
        #expect(values.count == 1)
        #expect(values[0].message == "token=<redacted> https://x/y")
    }

    @Test func redactsEscapedSimulatorPaths() {
        let value = AppDiagnostics.redact(
            """
            {"path":"\\/Users\\/person\\/Library\\/Developer\\/CoreSimulator\\/Devices\\/A\\/app",
             "token":"value"}
            {"password":"prefix\\\"sensitive-suffix"}
            Authorization: Bearer credential
            password = value API_KEY: key
            /Users/First Last/private
            https://person:password@example.com/path?q=1
            """)
        #expect(!value.contains("Users"))
        #expect(!value.contains("CoreSimulator/Devices"))
        #expect(!value.contains("credential"))
        #expect(!value.contains("password = value"))
        #expect(!value.contains("API_KEY: key"))
        #expect(!value.contains("sensitive-suffix"))
        #expect(!value.contains("First Last"))
        #expect(!value.contains("person:password"))
        #expect(value.contains("<redacted-path>"))
    }

    @Test func scansOnlyRegularMatchingReports() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let device = UUID()
        let now = Date()
        let timestamp = crashTimestamp(now)
        let incident = UUID()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let valid = root.appendingPathComponent("valid.ips")
        let metadata =
            #"{"bundleID":"dev.example","incident_id":"\#(incident)","app_name":"Example","#
            + #""timestamp":"\#(timestamp)"}"#
        let body =
            #"{"procPath":"/Users/USER/Library/Developer/CoreSimulator/Devices/\#(device)/app","#
            + #""password":"hunter2","exception":{"type":"EXC_CRASH","signal":"SIGABRT"}}"#
        try Data("\(metadata)\n\(body)".utf8).write(to: valid)
        try Data(
            """
            {"is_simulated":1,"bundleID":"dev.other"}
            unrelated
            """.utf8
        ).write(to: root.appendingPathComponent("other.ips"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link.ips"), withDestinationURL: valid)
        try #require(mkfifo(root.appendingPathComponent("pipe.ips").path, 0o600) == 0)
        _ = try AppDiagnostics.crashFile(
            valid, device: device, bundle: "dev.example", since: 60, now: now,
            until: .now.advanced(by: .seconds(1)))
        let reports = try AppDiagnostics.scanCrashes(
            directory: root, device: device, bundle: "dev.example", since: 60,
            limit: 10, now: now)
        #expect(reports.count == 1)
        let report = try #require(reports.first)
        #expect(report.incidentId == incident.uuidString)
        #expect(report.process == "Example")
        #expect(report.summary == "exception=EXC_CRASH signal=SIGABRT")
        #expect(!report.summary.contains("hunter2"))
        let wrongDevice = try AppDiagnostics.scanCrashes(
            directory: root, device: UUID(), bundle: "dev.example", since: 60,
            limit: 10, now: now)
        #expect(wrongDevice.isEmpty)
        #expect(throws: RuntimeFailure.self) {
            _ = try AppDiagnostics.scanCrashes(
                directory: root, device: device, bundle: "dev.example", since: 60,
                limit: 10, now: now, until: .now)
        }
    }

    @Test func malformedAndOversizeCrashReportsAreIgnored() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let device = UUID()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not json".utf8).write(to: root.appendingPathComponent("bad.ips"))
        let oversized = root.appendingPathComponent("large.ips")
        FileManager.default.createFile(atPath: oversized.path, contents: nil)
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: 4 * 1_024 * 1_024 + 1)
        try handle.close()
        let reports = try AppDiagnostics.scanCrashes(
            directory: root, device: device, bundle: "dev.example", since: 60,
            limit: 10, now: Date())
        #expect(reports.isEmpty)
    }
}

private func crashTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SS Z"
    return formatter.string(from: date)
}
