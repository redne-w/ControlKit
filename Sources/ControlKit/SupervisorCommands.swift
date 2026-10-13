import ArgumentParser
import ControlKitRuntime
import ControlKitSupervisor
import ControlKitWire
import Foundation

struct InternalSupervisor: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "_supervisor", abstract: "Internal local supervisor.", shouldDisplay: false)
    @Option var source: String
    @Option var cache: String

    mutating func run() throws {
        try SupervisorServer(
            source: URL(fileURLWithPath: source).resolvingSymlinksInPath(),
            cache: URL(fileURLWithPath: cache).standardizedFileURL
        ).run()
    }
}

struct OutputOptions: ParsableArguments {
    @Flag(help: "Emit one versioned JSON result. Implies noninteractive behavior.")
    var json = false
    @Flag(help: "Never prompt for input.")
    var nonInteractive = false
    @Option(help: "Finite command deadline in seconds; command-specific maximum applies.")
    var timeout: Double?

    func milliseconds(
        default defaultSeconds: Double, minimum: Double = 0.001, maximum: Double
    ) throws -> UInt64 {
        let value = timeout ?? defaultSeconds
        guard value.isFinite, value >= minimum, value <= maximum else {
            throw ValidationError("Timeout must be \(minimum)–\(maximum) seconds.")
        }
        return UInt64(value * 1_000)
    }
}

struct CommandRequestIdentity: ParsableArguments {
    @Option(
        name: .customLong("request-id"), help: "Caller-chosen UUID; duplicates never reexecute.")
    var requestId: String?

    func apply(_ request: inout SupervisorRequest) throws {
        guard let requestId else { return }
        guard let id = UUID(uuidString: requestId) else {
            throw ValidationError("Invalid request UUID.")
        }
        request.requestId = id
    }
}

enum SupervisorCLI {
    static func request(_ operation: String, milliseconds: UInt64) throws -> SupervisorRequest {
        let budget = OperationBudget(milliseconds: milliseconds)
        let tools = try AppleTools(budget: budget)
        return SupervisorRequest(
            operation: operation, toolchain: tools.identity,
            remainingMilliseconds: try budget.remaining(maximum: milliseconds))
    }

    static func perform(_ request: SupervisorRequest, json: Bool) throws {
        guard let executableURL = Bundle.main.executableURL else {
            throw ValidationError("Cannot resolve the running ControlKit executable.")
        }
        let executable = executableURL.standardizedFileURL.resolvingSymlinksInPath()
        let environment = ProcessInfo.processInfo.environment
        let installed = executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("share/ControlKit", isDirectory: true)
        let root = environment["CONTROLKIT_SOURCE_ROOT"] ?? installed.path
        let source = URL(fileURLWithPath: root).resolvingSymlinksInPath()
        guard
            FileManager.default.fileExists(
                atPath: source.appendingPathComponent("Helper/RuntimeTests.swift").path)
        else {
            throw ValidationError(
                "Helper sources are missing; reinstall or set "
                    + "CONTROLKIT_SOURCE_ROOT for development."
            )
        }
        let cache = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(
                "Library/Caches/ControlKit-session-helper-v1", isDirectory: true)
        let response: SupervisorResponse
        do {
            response = try SupervisorClient.perform(
                request, executable: executable, source: source, cache: cache)
        } catch SupervisorClientFailure.cancelled(let sent) {
            let code = sent ? "outcome_unknown" : "cancelled"
            let message =
                sent
                ? "Interrupted after send; query the receipt instead of replaying."
                : "Interrupted before sending the request."
            let interrupted = SupervisorResponse(
                request: request, epoch: nil, session: request.sessionId,
                generation: request.helperGeneration,
                completion: sent ? .unknown : .notDispatched,
                error: SupervisorError(code: code, message: message))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            FileHandle.standardOutput.write(try encoder.encode(interrupted) + Data([10]))
            throw ExitCode(130)
        }
        record(request, response)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if json {
            FileHandle.standardOutput.write(try encoder.encode(response) + Data([10]))
        } else {
            printHuman(response)
        }
        if !response.ok {
            if response.completion == .unknown { throw ExitCode(4) }
            let invalid = ["invalid_argument", "configuration_missing", "toolchain_mismatch"]
            throw ExitCode(invalid.contains(response.error?.code ?? "") ? 2 : 3)
        }
    }

    private static func record(_ request: SupervisorRequest, _ response: SupervisorResponse) {
        DiagnosticLog.record(
            "cli.response",
            [
                "operation": request.operation, "request": request.requestId.uuidString,
                "session": response.sessionId?.uuidString ?? "none",
                "completion": response.completion.rawValue,
                "errorCode": response.error?.code ?? "none",
                "errorMessage": response.error?.message ?? "none",
            ])
    }

    private static func printHuman(_ response: SupervisorResponse) {
        if let error = response.error {
            print("\(error.code): \(error.message)")
            fflush(stdout)
            // Error text stays fixed-phase; tool output and failure causes live in the log.
            FileHandle.standardError.write(
                Data(
                    ("Details: ~/Library/Logs/ControlKit. "
                        + "Run 'ControlKit report' to package them for the ControlKit team.\n")
                        .utf8))
        } else if let session = response.data?.session {
            let identity = session.id.uuidString
            print("\(identity) \(session.state.rawValue) generation=\(session.generation)")
        } else if let sessions = response.data?.sessions {
            for session in sessions {
                let identity = session.id.uuidString
                let device = session.device.uuidString
                print("\(identity) \(device) \(session.state.rawValue)")
            }
        } else if let snapshot = response.data?.ui?.snapshot {
            print("snapshot=\(snapshot.id.uuidString) nodes=\(snapshot.emittedCount)")
        } else if let path = response.data?.screenshotPath {
            print(path)
        } else if let devices = response.data?.devices {
            for device in devices {
                print("\(device.udid.uuidString) \(device.state) \(device.name)")
            }
        } else if let artifact = response.data?.artifact {
            print("\(artifact.bundleIdentifier) \(artifact.path)")
        } else if let launch = response.data?.launch {
            print("\(launch.bundleIdentifier) pid=\(launch.processIdentifier)")
        } else if let steps = response.data?.completedSteps {
            print(steps.joined(separator: " -> "))
        } else if let findings = response.data?.findings {
            for finding in findings {
                print("\(finding.severity) \(finding.code): \(finding.message)")
            }
            if let path = response.data?.configurationPath { print(path) }
        } else if let logs = response.data?.appLogs {
            print(
                "\(logs.bundleIdentifier) \(logs.device.uuidString) "
                    + "entries=\(logs.entries.count) scope=\(logs.scope)")
            for event in logs.entries {
                let level = event.level.map { " \($0)" } ?? ""
                print("\(event.timestamp)\(level) \(event.process): \(event.message)")
            }
        } else if let crashes = response.data?.appCrashes {
            print(
                "\(crashes.bundleIdentifier) \(crashes.device.uuidString) "
                    + "reports=\(crashes.reports.count) scope=\(crashes.scope)")
            for report in crashes.reports {
                let timestamp = report.timestamp ?? "unknown-time"
                let process = report.process ?? "unknown-process"
                print("\(timestamp) \(process) \(report.incidentId): \(report.summary)")
            }
        } else if let logs = response.data?.logs {
            for event in logs {
                print("\(event.monotonicMilliseconds) \(event.code)")
            }
        } else {
            print("ok")
        }
    }
}

struct SessionIdentity: ParsableArguments {
    @Option(help: "Explicit session UUID.")
    var session: String

    func id() throws -> UUID {
        guard let value = UUID(uuidString: session) else {
            throw ValidationError("Invalid session UUID.")
        }
        return value
    }
}

struct Sessions: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "session", abstract: "Manage owned simulator automation sessions.",
        discussion: """
            Start attaches to an already booted simulator and foreground app.
            It never launches either.
            One session owns a simulator. Unknown outcomes require recover, then a fresh inspection.
            """,
        subcommands: [
            SessionStart.self, SessionList.self, SessionStatus.self,
            SessionRecover.self, SessionStop.self,
        ])
}

struct SessionStart: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start", abstract: "Attach an authenticated helper without launching the app.",
        discussion: """
            Example: ControlKit session start --device <udid> --app dev.example.app --json
            Side effects: starts XCTest automation only; preserves app process/data and simulator.
            """)
    @Option(help: "Booted simulator UDID.") var device: String
    @Option(help: "Foreground app bundle identifier.") var app: String
    @OptionGroup var requestIdentity: CommandRequestIdentity
    @OptionGroup var output: OutputOptions

    mutating func run() throws {
        guard let device = UUID(uuidString: device) else {
            throw ValidationError("Invalid device UDID.")
        }
        var request = try SupervisorCLI.request(
            "session.start", milliseconds: output.milliseconds(default: 120, maximum: 180))
        request.device = device
        request.app = app
        try requestIdentity.apply(&request)
        try SupervisorCLI.perform(request, json: output.json)
    }
}

struct SessionList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list", abstract: "List sessions owned by this local supervisor.")
    @OptionGroup var requestIdentity: CommandRequestIdentity
    @OptionGroup var output: OutputOptions

    mutating func run() throws {
        var request = try SupervisorCLI.request(
            "session.list", milliseconds: output.milliseconds(default: 5, maximum: 30))
        try requestIdentity.apply(&request)
        try SupervisorCLI.perform(request, json: output.json)
    }
}

struct SessionStatus: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "Read session state or one non-replaying request receipt.",
        discussion: "Example: ControlKit session status --session <uuid> --request-id <uuid> --json"
    )
    @OptionGroup var identity: SessionIdentity
    @Option(help: "Accepted request UUID to query without repeating it.") var requestId: String?
    @OptionGroup var output: OutputOptions

    mutating func run() throws {
        var request = try SupervisorCLI.request(
            "session.status", milliseconds: output.milliseconds(default: 5, maximum: 30))
        request.sessionId = try identity.id()
        if let requestId {
            guard let value = UUID(uuidString: requestId) else {
                throw ValidationError("Invalid request UUID.")
            }
            request.receiptId = value
        }
        try SupervisorCLI.perform(request, json: output.json)
    }
}

struct SessionRecover: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recover", abstract: "Retire the old runner and require a fresh inspection.",
        discussion:
            "Never replays an uncertain action. "
            + "Example: ControlKit session recover --session <uuid>"
    )
    @OptionGroup var identity: SessionIdentity
    @OptionGroup var requestIdentity: CommandRequestIdentity
    @OptionGroup var output: OutputOptions

    mutating func run() throws {
        var request = try SupervisorCLI.request(
            "session.recover", milliseconds: output.milliseconds(default: 120, maximum: 180))
        request.sessionId = try identity.id()
        try requestIdentity.apply(&request)
        try SupervisorCLI.perform(request, json: output.json)
    }
}

struct SessionStop: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop", abstract: "Retire automation; retain app data/process and simulator.",
        discussion: "Example: ControlKit session stop --session <uuid> --json")
    @OptionGroup var identity: SessionIdentity
    @OptionGroup var requestIdentity: CommandRequestIdentity
    @OptionGroup var output: OutputOptions

    mutating func run() throws {
        var request = try SupervisorCLI.request(
            "session.stop", milliseconds: output.milliseconds(default: 10, maximum: 30))
        request.sessionId = try identity.id()
        try requestIdentity.apply(&request)
        try SupervisorCLI.perform(request, json: output.json)
    }
}
