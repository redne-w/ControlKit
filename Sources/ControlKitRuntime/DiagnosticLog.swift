import ControlKitProcess
import Darwin
import Foundation

/// Persistent local diagnostics that testers return with `ControlKit report`.
///
/// Logging is best effort: a full disk or unwritable home must never change a command's result,
/// so write failures are dropped. Files are owner-only, total size is bounded, and every value is
/// stripped of credentials and the home-directory prefix before it reaches disk.
package enum DiagnosticLog {
    package static let logName = "controlkit.log"
    package static let rotatedLogName = "controlkit.1.log"
    package static let supervisorErrorName = "supervisor-stderr.log"
    package static let failureDirectoryName = "tool-failures"
    /// Two generations bound the event log to 8 MiB plus one final line.
    static let maximumLogBytes: off_t = 4 * 1_024 * 1_024
    static let maximumValueBytes = 8_192
    /// One capture keeps at most 1 MiB per stream; ten captures bound that folder to 20 MiB.
    static let maximumCapturedStreamBytes = 1_024 * 1_024
    static let maximumFailureCaptures = 10
    static let maximumErrorLines = 20

    package static let component: String =
        CommandLine.arguments.dropFirst().first == "_supervisor" ? "supervisor" : "cli"

    /// `CONTROLKIT_LOG_DIRECTORY` exists for tests; the detached supervisor inherits it.
    package static func directoryURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let value = environment["CONTROLKIT_LOG_DIRECTORY"], value.hasPrefix("/") {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Logs/ControlKit", isDirectory: true)
    }

    package static func record(
        _ event: String, _ fields: [String: String] = [:], in directory: URL = directoryURL()
    ) {
        guard let folder = try? PrivateDirectory(directory) else { return }
        try? append(line(event: event, fields: fields), in: folder)
    }

    package static func failure(
        _ event: String, _ error: any Error, _ fields: [String: String] = [:],
        in directory: URL = directoryURL()
    ) {
        var values = fields
        values["error"] = describe(error)
        record(event, values, in: directory)
    }

    /// Type-qualified text keeps enum failures such as `WireFailure.deadlineExceeded` legible.
    package static func describe(_ error: any Error) -> String {
        if let failure = error as? RuntimeFailure { return "\(failure.code): \(failure.message)" }
        return String(reflecting: error)
    }

    package static func sanitize(_ text: String) -> String {
        let home = NSHomeDirectory()
        let local = home.count > 1 ? text.replacingOccurrences(of: home, with: "~") : text
        return AppDiagnostics.redactCredentials(local)
    }

    /// UI text may be a password, so `--text` values never reach disk.
    package static func sanitize(arguments: [String]) -> String {
        var values: [String] = []
        var hideNext = false
        for argument in arguments.prefix(128) {
            if hideNext {
                values.append("<redacted>")
                hideNext = false
            } else if argument.hasPrefix("--text=") {
                values.append("--text=<redacted>")
            } else {
                hideNext = argument == "--text"
                values.append(argument)
            }
        }
        return sanitize(values.joined(separator: " "))
    }

    static func line(event: String, fields: [String: String]) throws -> Data {
        struct Entry: Encodable {
            let time: String
            let pid: Int32
            let component: String
            let version: String
            let event: String
            let fields: [String: String]
        }
        let entry = Entry(
            time: Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(Date()),
            pid: getpid(), component: component, version: ControlKitVersion.description,
            event: event,
            fields: fields.mapValues { prefix(sanitize($0), bytes: maximumValueBytes) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(entry) + Data([10])
    }

    static func append(_ line: Data, in folder: PrivateDirectory) throws {
        let file = try folder.openFile(logName, flags: O_WRONLY | O_CREAT | O_APPEND)
        defer { close(file) }
        try writeAll(file, line)
        var info = stat()
        guard fstat(file, &info) == 0, info.st_size > maximumLogBytes else { return }
        // One process rotates. Writers that lose the lock keep appending whole O_APPEND lines.
        guard let lock = try? FileLock(directory: folder, name: "rotate.lock") else { return }
        defer { withExtendedLifetime(lock) {} }
        var current = stat()
        guard fstatat(folder.descriptor, logName, &current, AT_SYMLINK_NOFOLLOW) == 0,
            current.st_size > maximumLogBytes
        else { return }
        try folder.rename(logName, to: rotatedLogName)
    }

    static func writeAll(_ file: Int32, _ data: Data) throws {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes {
                Darwin.write(file, $0.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw RuntimeFailure("private_files", "Cannot write diagnostic log.")
            }
            offset += count
        }
    }

    static func prefix(_ text: String, bytes: Int) -> String {
        text.utf8.count <= bytes ? text : String(decoding: text.utf8.prefix(bytes), as: UTF8.self)
    }

    static func suffix(_ data: Data, bytes: Int) -> String {
        String(decoding: data.suffix(bytes), as: UTF8.self)
    }
}
