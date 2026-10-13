import Darwin
import Foundation

package struct AppLogEvent: Codable, Sendable {
    package let timestamp: String
    package let process: String
    package let subsystem: String?
    package let category: String?
    package let level: String?
    package let message: String
}

package struct AppLogResult: Codable, Sendable {
    package let device: UUID
    package let bundleIdentifier: String
    package let executable: String
    package let scope: String
    package let bundleAssociationVerified: Bool
    package let sinceSeconds: Int
    package let entries: [AppLogEvent]
}

package struct AppCrashReport: Codable, Sendable {
    package let incidentId: String
    package let timestamp: String?
    package let process: String?
    package let bundleIdentifier: String
    package let summary: String
}

package struct AppCrashResult: Codable, Sendable {
    package let device: UUID
    package let bundleIdentifier: String
    package let executable: String
    package let scope: String
    package let deviceAssociationVerified: Bool
    package let sinceSeconds: Int
    package let reports: [AppCrashReport]
}

package enum AppDiagnostics {
    private struct InstalledApp {
        let executable: String
    }

    package static func logs(
        tools: AppleTools, device: UUID, bundle: String, since: Int, limit: Int,
        budget: OperationBudget
    ) throws -> AppLogResult {
        try validate(since, 1...3_600, "since")
        try validate(limit, 1...512, "limit")
        try validateDevice(tools, device, budget)
        let app = try resolveApp(tools, device, bundle, budget)
        let predicate = "process == \(predicateLiteral(app.executable))"
        let output = try tools.run(
            [
                "simctl", "spawn", device.uuidString, "log", "show", "--style", "json",
                "--last", "\(since)s", "--predicate", predicate,
            ],
            milliseconds: 60_000, budget: budget, label: "app_logs")
        let entries = try parseLogs(output, process: app.executable, limit: limit)
        return AppLogResult(
            device: device, bundleIdentifier: bundle, executable: app.executable,
            scope: "resolved_executable_name", bundleAssociationVerified: false,
            sinceSeconds: since, entries: entries)
    }

    package static func crashes(
        tools: AppleTools, device: UUID, bundle: String, since: Int, limit: Int,
        budget: OperationBudget
    ) throws -> AppCrashResult {
        try validate(since, 1...86_400, "since")
        try validate(limit, 1...32, "limit")
        try validateDevice(tools, device, budget)
        let app = try resolveApp(tools, device, bundle, budget)
        let directory = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/DiagnosticReports")
        let reports = try scanCrashes(
            directory: directory, device: device, bundle: bundle, since: since,
            limit: limit, now: Date(), until: budget.end)
        return AppCrashResult(
            device: device, bundleIdentifier: bundle, executable: app.executable,
            scope: "selected_simulator", deviceAssociationVerified: true,
            sinceSeconds: since, reports: reports)
    }

    private static func resolveApp(
        _ tools: AppleTools, _ device: UUID, _ bundle: String, _ budget: OperationBudget
    ) throws -> InstalledApp {
        try validateRuntimeText(bundle, limit: 255)
        let data = try tools.run(
            ["simctl", "get_app_container", device.uuidString, bundle, "app"], budget: budget,
            label: "app_container")
        return try installedApp(container: data, bundle: bundle)
    }

    private static func installedApp(container data: Data, bundle: String) throws -> InstalledApp {
        try requireRuntime(
            data.count <= 4_096, "resource_limit", "App container path exceeds its limit.")
        guard let text = String(data: data, encoding: .utf8) else {
            throw RuntimeFailure("tool_output", "App container path is not UTF-8.")
        }
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        try validateRuntimeText(path, limit: 4_096)
        let container = URL(fileURLWithPath: path).standardizedFileURL
        try requireRuntime(
            container.pathExtension == "app" && container.path.hasPrefix("/"),
            "tool_output", "App container path is invalid.")
        let plist = try RuntimeFiles.read(
            container.appendingPathComponent("Info.plist"), limit: 1_024 * 1_024)
        let executable = try executable(plist: plist, bundle: bundle)
        return InstalledApp(executable: executable)
    }

    package static func executable(plist data: Data, bundle: String) throws -> String {
        guard
            let app = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
            app["CFBundleIdentifier"] as? String == bundle,
            let executable = app["CFBundleExecutable"] as? String
        else { throw RuntimeFailure("app_missing", "Exact bundle ID is not installed.") }
        try validateRuntimeText(executable, limit: 255)
        return executable
    }

    package static func parseLogs(
        _ data: Data, process: String, limit: Int
    ) throws -> [AppLogEvent] {
        try requireRuntime(
            data.count <= 8 * 1_024 * 1_024, "resource_limit",
            "Log tool output exceeds its limit.")
        let objects = try jsonObjects(data)
        var result: [AppLogEvent] = []
        var bytes = 0
        for object in objects {
            let eventImagePath = object["processImagePath"] as? String
            let processName =
                object["process"] as? String
                ?? eventImagePath.map { URL(fileURLWithPath: $0).lastPathComponent }
            guard result.count < limit, let exactProcess = processName, exactProcess == process
            else { continue }
            let message = redact(String(describing: object["eventMessage"] ?? ""))
            let bounded = String(decoding: message.utf8.prefix(4_096), as: UTF8.self)
            let event = AppLogEvent(
                timestamp: boundedRedacted(object["timestamp"] as? String) ?? "",
                process: exactProcess,
                subsystem: boundedRedacted(object["subsystem"] as? String),
                category: boundedRedacted(object["category"] as? String),
                level: boundedRedacted(object["messageType"] as? String), message: bounded)
            let encoded = try JSONEncoder().encode(event)
            if bytes + encoded.count > 1_048_576 { break }
            bytes += encoded.count
            result.append(event)
        }
        return result
    }

    package static func scanCrashes(
        directory: URL, device: UUID, bundle: String, since: Int, limit: Int, now: Date,
        until deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(5))
    ) throws -> [AppCrashReport] {
        var root = stat()
        if lstat(directory.path, &root) != 0, errno == ENOENT { return [] }
        let names = try RuntimeFiles.entries(directory, limit: 2_048).sorted(by: >)
        var matches: [(Date, String, AppCrashReport)] = []
        for name in names where name.hasSuffix(".ips") {
            try requireRuntime(
                ContinuousClock.now < deadline, "deadline_exceeded",
                "Crash report scan exceeded its deadline.")
            let url = directory.appendingPathComponent(name)
            do {
                let item = try crashFile(
                    url, device: device, bundle: bundle, since: since, now: now,
                    until: deadline)
                matches.append((item.0, name, item.1))
            } catch let failure as RuntimeFailure {
                if failure.code == "deadline_exceeded" { throw failure }
            } catch {
                continue
            }
        }
        matches.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 > $1.0 }
        var result: [AppCrashReport] = []
        var bytes = 0
        for item in matches.prefix(limit) {
            let size = (try? JSONEncoder().encode(item.2).count) ?? 1_048_577
            if bytes + size > 1_048_576 { break }
            bytes += size
            result.append(item.2)
        }
        return result
    }

    private static func validateDevice(
        _ tools: AppleTools, _ id: UUID, _ budget: OperationBudget
    ) throws {
        let device = try SimulatorOperations(tools: tools).device(id, budget: budget)
        try requireRuntime(
            device.state == "Booted", "device_not_booted",
            "Choose an available Booted simulator UDID.")
    }

    private static func validate(_ value: Int, _ range: ClosedRange<Int>, _ name: String) throws {
        try requireRuntime(range.contains(value), "invalid_argument", "Invalid \(name) bound.")
    }

    private static func predicateLiteral(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return "'\(escaped)'"
    }

    private static func jsonObjects(_ data: Data) throws -> [[String: Any]] {
        if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return array
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw RuntimeFailure("tool_output", "Log output is not UTF-8.")
        }
        let values = text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        try requireRuntime(
            !values.isEmpty || text.isEmpty, "tool_output",
            "Log output is not structured JSON.")
        return values
    }

    package static func crashFile(
        _ url: URL, device: UUID, bundle: String, since: Int, now: Date,
        until deadline: ContinuousClock.Instant
    ) throws -> (Date, AppCrashReport) {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        try requireRuntime(
            descriptor >= 0, "invalid_file", "Crash report cannot be opened safely.")
        defer { close(descriptor) }
        var info = stat()
        try requireRuntime(
            fstat(descriptor, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG,
            "invalid_file", "Crash report is not a regular file.")
        try requireRuntime(
            info.st_size <= 4 * 1_024 * 1_024, "resource_limit",
            "Crash report exceeds its file limit.")
        let data = try readCrash(descriptor, expected: Int(info.st_size), until: deadline)
        guard let newline = data.firstIndex(of: 10),
            let metadata = try? JSONSerialization.jsonObject(with: data[..<newline])
                as? [String: Any],
            (metadata["bundleID"] as? String) == bundle
        else { throw RuntimeFailure("unrelated", "Unrelated crash report.") }
        let bodyData = data.suffix(from: newline + 1)
        guard
            let bodyObject = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
            matchesDevice(bodyObject, device: device)
        else { throw RuntimeFailure("unrelated", "Crash report belongs to another simulator.") }
        guard let timestamp = metadata["timestamp"] as? String,
            let occurred = crashDate(timestamp)
        else { throw RuntimeFailure("invalid_file", "Crash timestamp is invalid.") }
        let age = now.timeIntervalSince(occurred)
        try requireRuntime(
            age >= -1 && age <= Double(since), "unrelated",
            "Crash report is outside the requested interval.")
        let suppliedIncident = metadata["incident_id"] as? String
        let incident =
            suppliedIncident.flatMap(UUID.init(uuidString:))?.uuidString
            ?? stableIncident(data)
        let process = boundedRedacted(
            metadata["procName"] as? String ?? metadata["app_name"] as? String
                ?? metadata["name"] as? String)
        return (
            occurred,
            AppCrashReport(
                incidentId: incident, timestamp: boundedRedacted(timestamp),
                process: process, bundleIdentifier: bundle, summary: crashSummary(bodyObject))
        )
    }

    private static func matchesDevice(_ body: [String: Any], device: UUID) -> Bool {
        let id = device.uuidString
        if body["coalitionName"] as? String == "com.apple.CoreSimulator.SimDevice.\(id)" {
            return true
        }
        guard let path = body["procPath"] as? String else { return false }
        return path.contains("/CoreSimulator/Devices/\(id)/")
    }

    private static func crashDate(_ value: String) -> Date? {
        for format in [
            "yyyy-MM-dd HH:mm:ss.SS Z", "yyyy-MM-dd HH:mm:ss.SSSSSS Z",
            "yyyy-MM-dd HH:mm:ss Z",
        ] {
            let parser = DateFormatter()
            parser.locale = Locale(identifier: "en_US_POSIX")
            parser.dateFormat = format
            if let date = parser.date(from: value) { return date }
        }
        return nil
    }

    private static func crashSummary(_ body: [String: Any]) -> String {
        var values: [String] = []
        if let exception = body["exception"] as? [String: Any] {
            if let type = boundedRedacted(exception["type"] as? String) {
                values.append("exception=\(type)")
            }
            if let signal = boundedRedacted(exception["signal"] as? String) {
                values.append("signal=\(signal)")
            }
        }
        if let termination = body["termination"] as? [String: Any] {
            if let namespace = boundedRedacted(termination["namespace"] as? String) {
                values.append("termination=\(namespace)")
            }
            if let code = termination["code"] { values.append("code=\(code)") }
        }
        if let thread = body["faultingThread"] as? Int { values.append("thread=\(thread)") }
        if values.isEmpty { return "No bounded exception summary is available." }
        return String(decoding: values.joined(separator: " ").utf8.prefix(4_096), as: UTF8.self)
    }

    private static func stableIncident(_ data: Data) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return String(format: "%016llx", hash)
    }

    private static func readCrash(
        _ descriptor: Int32, expected: Int, until deadline: ContinuousClock.Instant
    ) throws -> Data {
        var data = Data()
        data.reserveCapacity(expected)
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while data.count <= 4 * 1_024 * 1_024 {
            try requireRuntime(
                ContinuousClock.now < deadline, "deadline_exceeded",
                "Crash report read exceeded its deadline.")
            let count = read(descriptor, &buffer, buffer.count)
            if count == 0 { return data }
            try requireRuntime(count > 0, "invalid_file", "Crash report could not be read.")
            data.append(buffer, count: count)
        }
        throw RuntimeFailure("resource_limit", "Crash report grew beyond its file limit.")
    }

    private static func boundedRedacted(_ text: String?) -> String? {
        guard let text else { return nil }
        let value = redact(text)
        return String(decoding: value.utf8.prefix(4_096), as: UTF8.self)
    }

    package static func redact(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "\\/", with: "/")
        let jsonValuePattern =
            #"(?i)("(?:password|token|secret|authorization|api[_-]?key)"\s*:\s*")"#
            + #"(?:\\.|[^"\\])*"#
        value = value.replacingOccurrences(
            of: jsonValuePattern,
            with: "$1<redacted>", options: .regularExpression)
        let keyValuePattern =
            #"(?i)\b(password|token|secret|authorization|api[_-]?key)\b"#
            + #"\s*[:=]\s*(?:Bearer\s+)?[^\s,&;"]+"#
        value = value.replacingOccurrences(
            of: keyValuePattern,
            with: "$1=<redacted>", options: .regularExpression)
        value = value.replacingOccurrences(
            of: #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#, with: "Bearer <redacted>",
            options: .regularExpression)
        value = value.replacingOccurrences(
            of: #"/Users/[^\n\r"]+"#, with: "<redacted-path>",
            options: .regularExpression)
        value = value.replacingOccurrences(
            of: #"/(?:private/var|var)/[^\s"]*"#, with: "<redacted-path>",
            options: .regularExpression)
        value = value.replacingOccurrences(
            of: #"/[^\s"]*CoreSimulator/Devices/[^\s"]*"#, with: "<redacted-path>",
            options: .regularExpression)
        value = value.replacingOccurrences(
            of: #"([a-zA-Z][a-zA-Z0-9+.-]*://)[^/@\s"]+@"#, with: "$1<redacted>@",
            options: .regularExpression)
        value = value.replacingOccurrences(
            of: #"([a-zA-Z][a-zA-Z0-9+.-]*://[^?\s#]+)[?#][^\s"]*"#, with: "$1",
            options: .regularExpression)
        return value
    }
}
