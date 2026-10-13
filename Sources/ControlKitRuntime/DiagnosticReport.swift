import ControlKitProcess
import Darwin
import Foundation

/// Packages local diagnostics into one archive a tester can send. Every collected file is
/// sanitized again, so files written before a sanitizer change or by Apple tools are covered.
package enum DiagnosticReport {
    static let maximumCopiedFileBytes = 16 * 1_024 * 1_024
    static let maximumCrashReports = 5

    package struct Inputs {
        package let executable: URL
        package let workingDirectory: URL
        package let outputDirectory: URL
        package let logDirectory: URL
        package let crashDirectory: URL

        package init(
            executable: URL, workingDirectory: URL, outputDirectory: URL,
            logDirectory: URL = DiagnosticLog.directoryURL(),
            crashDirectory: URL = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Logs/DiagnosticReports")
        ) {
            self.executable = executable
            self.workingDirectory = workingDirectory
            self.outputDirectory = outputDirectory
            self.logDirectory = logDirectory
            self.crashDirectory = crashDirectory
        }
    }

    package static func create(_ inputs: Inputs, includeCommands: Bool = true) throws -> URL {
        let stamp = Date.ISO8601FormatStyle(
            dateSeparator: .omitted, timeSeparator: .omitted
        ).format(Date())
        let name = "ControlKit-report-\(stamp)"
        let archive = inputs.outputDirectory.appendingPathComponent("\(name).zip")
        try requireRuntime(
            !FileManager.default.fileExists(atPath: archive.path), "invalid_argument",
            "Report archive already exists; wait one second or choose another directory.")
        let parent = try PrivateDirectory(
            URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .resolvingSymlinksInPath()
                .appendingPathComponent("ControlKit-report-\(getpid())-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: parent.url) }
        let staging = try PrivateDirectory(parent.url.appendingPathComponent(name))
        try save(summary(inputs), as: "summary.txt", in: staging.url)
        // Commands run first so the doctor's own log records land in the copied logs.
        if includeCommands { try collectCommands(inputs, into: staging.url) }
        try collectLogs(from: inputs.logDirectory, into: staging.url)
        try collectCrashes(from: inputs.crashDirectory, into: staging.url)
        let zipped = try run(
            "/usr/bin/ditto", ["-c", "-k", "--keepParent", staging.url.path, archive.path],
            directory: "/", seconds: 120)
        try requireRuntime(
            zipped.succeeded, "report_failed", "Could not create the report archive.")
        DiagnosticLog.record(
            "report.created", ["archive": archive.path], in: inputs.logDirectory)
        return archive
    }

    static func summary(_ inputs: Inputs) -> String {
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: &system.machine) {
            String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let environment = ProcessInfo.processInfo.environment
        return """
            ControlKit: \(ControlKitVersion.description)
            Executable: \(inputs.executable.path)
            Created: \(Date.ISO8601FormatStyle().format(Date()))
            macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
            Architecture: \(machine)
            Working directory: \(inputs.workingDirectory.path)
            DEVELOPER_DIR: \(environment["DEVELOPER_DIR"] ?? "(unset)")
            Log directory: \(inputs.logDirectory.path)

            """
    }

    static func collectCommands(_ inputs: Inputs, into staging: URL) throws {
        let commands: [(String, String, [String])] = [
            ("sw_vers", "/usr/bin/sw_vers", []),
            ("xcode-select", "/usr/bin/xcode-select", ["-p"]),
            ("xcodebuild-version", "/usr/bin/xcrun", ["xcodebuild", "-version"]),
            ("simctl-runtimes", "/usr/bin/xcrun", ["simctl", "list", "runtimes"]),
            ("simctl-devices", "/usr/bin/xcrun", ["simctl", "list", "devices"]),
            ("doctor", inputs.executable.path, ["doctor", "--json", "--non-interactive"]),
        ]
        for (name, executable, arguments) in commands {
            var text = "$ \(([executable] + arguments).joined(separator: " "))\n"
            do {
                let result = try run(
                    executable, arguments, directory: inputs.workingDirectory.path, seconds: 90)
                text += "reason: \(result.reason.rawValue)"
                text += " exit: \(result.exitCode.map { "\($0)" } ?? "none")\n"
                text += "--- stdout ---\n\(String(decoding: result.stdout, as: UTF8.self))\n"
                text += "--- stderr ---\n\(String(decoding: result.stderr, as: UTF8.self))\n"
            } catch {
                text += "not run: \(DiagnosticLog.describe(error))\n"
            }
            try save(text, as: "\(name).txt", in: staging.appendingPathComponent("commands"))
        }
    }

    static func collectLogs(from logs: URL, into staging: URL) throws {
        let target = staging.appendingPathComponent("logs")
        let names = [
            DiagnosticLog.rotatedLogName, DiagnosticLog.logName, DiagnosticLog.supervisorErrorName,
        ]
        for name in names { try copy(logs.appendingPathComponent(name), into: target) }
        let failures = logs.appendingPathComponent(DiagnosticLog.failureDirectoryName)
        let captures = (try? RuntimeFiles.entries(failures, limit: 256)) ?? []
        for name in captures where name.hasSuffix(".log") {
            try copy(
                failures.appendingPathComponent(name),
                into: target.appendingPathComponent(DiagnosticLog.failureDirectoryName))
        }
    }

    /// macOS names reports `ControlKit-<date>-<time>.ips`, so name order is age order.
    static func collectCrashes(from crashes: URL, into staging: URL) throws {
        let names = ((try? RuntimeFiles.entries(crashes, limit: 65_536)) ?? []).filter {
            $0.hasPrefix("ControlKit") && $0.hasSuffix(".ips")
        }
        for name in names.suffix(maximumCrashReports) {
            try copy(
                crashes.appendingPathComponent(name),
                into: staging.appendingPathComponent("crash-reports"))
        }
    }

    /// Missing or oversized sources are noted instead of failing, so one bad file cannot block
    /// the rest of the report.
    static func copy(_ source: URL, into directory: URL) throws {
        let text: String
        do {
            let data = try RuntimeFiles.read(source, limit: maximumCopiedFileBytes)
            text = String(decoding: data, as: UTF8.self)
        } catch {
            guard FileManager.default.fileExists(atPath: source.path) else { return }
            text = "not collected: \(DiagnosticLog.describe(error))\n"
        }
        try save(text, as: source.lastPathComponent, in: directory)
    }

    static func save(_ text: String, as name: String, in directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try Data(DiagnosticLog.sanitize(text).utf8).write(
            to: directory.appendingPathComponent(name), options: .withoutOverwriting)
    }

    static func run(
        _ executable: String, _ arguments: [String], directory: String, seconds: UInt64
    ) throws -> ProcessResult {
        let inherited = ProcessInfo.processInfo.environment
        var environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(),
            "TMPDIR": NSTemporaryDirectory(), "LC_ALL": "en_US.UTF-8",
        ]
        for key in ["DEVELOPER_DIR", "CONTROLKIT_SOURCE_ROOT", "CONTROLKIT_LOG_DIRECTORY"] {
            environment[key] = inherited[key]
        }
        return try OwnedProcess(
            ProcessCommand(
                executable: executable, arguments: arguments, environment: environment,
                directory: directory, timeoutMilliseconds: seconds * 1_000,
                outputLimit: 4 * 1_024 * 1_024)
        ).wait()
    }
}
