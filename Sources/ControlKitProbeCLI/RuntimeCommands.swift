import ArgumentParser
import ControlKitRuntime
import Foundation

private struct RuntimeResponse<Value: Encodable>: Encodable {
    let ok: Bool
    let data: Value?
    let error: RuntimeFailure?
}

func runtimeResult<Value: Encodable>(_ operation: (AppleTools) throws -> Value) throws {
    let cancellation = CancellationSignal()
    let response: RuntimeResponse<Value>
    do {
        let tools = try AppleTools(cancellation: cancellation)
        response = RuntimeResponse(ok: true, data: try operation(tools), error: nil)
    } catch {
        let failure =
            error as? RuntimeFailure
            ?? RuntimeFailure("runtime_failed", "Runtime operation failed; no automatic retry.")
        response = RuntimeResponse(ok: false, data: nil, error: failure)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(response) + Data([10]))
    if cancellation.isRequested { throw ExitCode(130) }
    if !response.ok { throw ExitCode.failure }
}

struct Simulators: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sim", abstract: "Experimental bounded simulator operations; always JSON.",
        discussion: """
            Mutations require explicit device identity and use an exclusive ownership record.
            Interrupted or uncertain operations are not retried; a retained fence blocks reuse.
            No production supervisor or cross-command receipt registry exists yet.
            Examples: ControlKit probe sim list
                      ControlKit probe sim boot --device <udid>
            """,
        subcommands: [SimList.self, SimCreate.self, SimBoot.self, SimShutdown.self])
}

struct SimList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list", abstract: "List available simulators without modifying them.")

    mutating func run() throws {
        try runtimeResult { try SimulatorOperations(tools: $0).list() }
    }
}

struct SimCreate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create one simulator. Never retries an uncertain creation.",
        discussion: """
            All choices are required; no device/runtime default. Prints the new UDID as JSON.
            Example: ControlKit probe sim create --name "ControlKit Development"
              --runtime com.apple.CoreSimulator.SimRuntime.iOS-26-4
              --device-type com.apple.CoreSimulator.SimDeviceType.iPhone-17
            """)
    @Option(help: "New simulator name, maximum 128 UTF-8 bytes.") var name: String
    @Option(help: "Exact installed com.apple.CoreSimulator.SimRuntime identifier.") var runtime:
        String
    @Option(help: "Exact com.apple.CoreSimulator.SimDeviceType identifier.") var deviceType: String

    mutating func run() throws {
        try runtimeResult {
            try SimulatorOperations(tools: $0).create(
                name: name, runtime: runtime, deviceType: deviceType)
        }
    }
}

struct DeviceArgument: ParsableArguments {
    @Option(help: "Explicit simulator UDID; never selects the first or currently booted device.")
    var device: String

    func id() throws -> UUID {
        guard let id = UUID(uuidString: device) else {
            throw ValidationError("Invalid device UDID.")
        }
        return id
    }
}

struct SimBoot: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "boot",
        abstract: "Boot one simulator and wait up to 120 seconds for readiness.",
        discussion: "Already booted is success. Example: ControlKit probe sim boot --device <udid>")
    @OptionGroup var target: DeviceArgument

    mutating func run() throws {
        let id = try target.id()
        try runtimeResult {
            try SimulatorOperations(tools: $0).boot(id)
            return ["device": id.uuidString, "state": "Booted"]
        }
    }
}

struct SimShutdown: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shutdown",
        abstract: "Shut down one simulator within 120 seconds; retains its data.",
        discussion:
            "Respects helper ownership. Example: ControlKit probe sim shutdown --device <udid>")
    @OptionGroup var target: DeviceArgument

    mutating func run() throws {
        let id = try target.id()
        try runtimeResult {
            try SimulatorOperations(tools: $0).shutdown(id)
            return ["device": id.uuidString, "state": "Shutdown"]
        }
    }
}

struct HelperCheck: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "helper-check",
        abstract:
            "Build/cache a lifecycle-only helper, authenticate, ping, stop, and verify retirement.",
        discussion: """
            Experimental acceptance command, not a production session. Requires a booted simulator.
            Installs/runs only ControlKitRuntime-Runner, never launches or resets a target app.
            Cache is bounded to four completed/incomplete entries; no automatic eviction.
            Private launch configuration/results are outside the repository. Do not share them.
            Example: ControlKit probe helper-check --device <udid>
              --source . --cache .build/helper-cache
            """)
    @OptionGroup var target: DeviceArgument
    @Option(help: "ControlKit source checkout. Includes the independent Helper Xcode project.")
    var source: String
    @Option(help: "Owner-only cache directory; parent must exist. No default/shared derived data.")
    var cache: String
    @Flag(
        help: "Fault check: close the authenticated connection after ping instead of sending stop.")
    var disconnectAfterPing = false

    mutating func run() throws {
        let id = try target.id()
        try runtimeResult {
            try HelperLifecycle.verify(
                source: URL(fileURLWithPath: source).standardizedFileURL.resolvingSymlinksInPath(),
                cache: URL(fileURLWithPath: cache).standardizedFileURL,
                device: id, tools: $0, disconnectAfterPing: disconnectAfterPing)
        }
    }
}
