import ControlKitProcess
import Darwin
import Foundation

extension DiagnosticLog {
    /// Keeps a failed Apple tool's output for bug reports. Command errors stay fixed-phase text,
    /// so this capture is the only place compiler and simctl failure detail survives.
    package static func toolFailure(
        label: String, arguments: [String], result: ProcessResult,
        in directory: URL = directoryURL()
    ) {
        var fields = [
            "label": label, "arguments": sanitize(arguments: arguments),
            "reason": result.reason.rawValue, "outputTruncated": "\(result.outputTruncated)",
            "exitCode": result.exitCode.map { "\($0)" } ?? "none",
            "signal": result.signal.map { "\($0)" } ?? "none",
            "stderrTail": suffix(result.stderr, bytes: 2_048),
        ]
        let errors = errorLines(result.stdout) + errorLines(result.stderr)
        if !errors.isEmpty {
            fields["errors"] = errors.prefix(maximumErrorLines).joined(separator: "\n")
        }
        if let name = try? capture(label: label, fields: fields, result: result, in: directory) {
            fields["capture"] = "\(failureDirectoryName)/\(name)"
        }
        record("tool.failed", fields, in: directory)
    }

    static func capture(
        label: String, fields: [String: String], result: ProcessResult, in directory: URL
    ) throws -> String {
        _ = try PrivateDirectory(directory)
        let captures = try PrivateDirectory(
            directory.appendingPathComponent(failureDirectoryName, isDirectory: true))
        let stamp = Date.ISO8601FormatStyle(
            dateSeparator: .omitted, timeSeparator: .omitted, includingFractionalSeconds: true
        ).format(Date())
        let safeLabel = String(
            label.unicodeScalars.prefix(48).map {
                CharacterSet.alphanumerics.contains($0) || $0 == "_" ? Character($0) : "-"
            })
        // The UTC stamp sorts captures oldest first. Failures can share a millisecond, and the
        // exclusive create would then drop one, so a random suffix keeps names distinct.
        let unique = UUID().uuidString.prefix(8)
        let name = "\(stamp)-\(safeLabel)-\(getpid())-\(unique).log"
        var text = ""
        for key in fields.keys.sorted() where key != "stderrTail" && key != "errors" {
            text += "\(key): \(fields[key]!)\n"
        }
        let limit = maximumCapturedStreamBytes
        text += "\n--- stdout (last \(limit) bytes) ---\n" + suffix(result.stdout, bytes: limit)
        text += "\n--- stderr (last \(limit) bytes) ---\n" + suffix(result.stderr, bytes: limit)
        let file = try captures.openFile(name, flags: O_WRONLY | O_CREAT | O_EXCL)
        defer { close(file) }
        try writeAll(file, Data(sanitize(text).utf8))
        let names = try captures.entries(limit: 256).filter { $0.hasSuffix(".log") }
        for old in names.dropLast(maximumFailureCaptures) { try captures.remove(old) }
        return name
    }

    /// xcodebuild prints compiler errors on stdout; these lines make the log useful on its own.
    static func errorLines(_ data: Data) -> [String] {
        var lines: [String] = []
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            guard line.contains("error:") || line.contains("** BUILD FAILED **") else { continue }
            lines.append(prefix(String(line), bytes: 512))
            if lines.count == maximumErrorLines { break }
        }
        return lines
    }
}
