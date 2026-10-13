import ArgumentParser
import ControlKitProbeCore
import Foundation

/// Kept separate so production commands cannot accidentally reuse the experimental wire contract.
package struct ProbeCommand: ParsableCommand {
    package init() {}

    package static let configuration = CommandConfiguration(
        commandName: "probe",
        abstract: "Experimental feasibility and discovery tools; this API is not stable.",
        subcommands: [Request.self, Discover.self, Simulators.self, HelperCheck.self]
    )
}

extension ProbeOperation: ExpressibleByArgument {}

struct Request: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Send one command to an already-running probe helper.",
        discussion: """
            Always prints one JSON response. Diagnostics go to stderr; failures exit nonzero.
            Use --connection with the private connection.json printed by 'just probe-serve'.
            Alternatively use --port with CONTROLKIT_PROBE_TOKEN in the environment.
            Never pass a token on the command line.
            Tap/type require an exact accessibility identifier. Swipe moves a finger upward
            in the identified container. Typing appends to the field after focusing it.
            Commands never launch/reset the app and are never retried.
            Screenshot requires --output and refuses to overwrite a file.
            Stop ends the helper test, not the target application or simulator.

            Examples:
              ControlKit probe request inspect --port 49200
              ControlKit probe request inspect --connection /private/tmp/probe/connection.json
              ControlKit probe request tap --port 49200 --id fixture.increment
              ControlKit probe request screenshot --port 49200 --output screen.png
            """
    )

    @Argument(help: "Operation: ping, inspect, tap, type, swipe, screenshot, or stop.")
    var operation: ProbeOperation

    @Option(help: "Loopback TCP port of the running helper.")
    var port: UInt16?

    @Option(help: "Private connection.json from probe-serve. Mutually exclusive with --port.")
    var connection: String?

    @Option(name: .customLong("id"), help: "Exact accessibility identifier; ambiguity is an error.")
    var identifier: String?

    @Option(help: "Text to append; Unicode is supported. Maximum 4096 characters.")
    var text: String?

    @Option(help: "New PNG file path. Required only for screenshot.")
    var output: String?

    @Option(
        help: "Client deadline in seconds, 0.1–120. Timeout does not cancel a dispatched action.")
    var timeout: Double = 30

    mutating func run() throws {
        let id = UUID()
        var response: ProbeResponse
        do {
            try validateOutput()
            let endpoint = try resolveConnection()
            let request = ProbeRequest(
                id: id, token: endpoint.token, operation: operation, identifier: identifier,
                text: text
            )
            response = try ProbeClient.send(request, port: endpoint.port, timeoutSeconds: timeout)
            try saveScreenshot(&response)
        } catch {
            response = ProbeResponse(id: id)
            response.ok = false
            response.error =
                error as? ProbeFailure
                ?? ProbeFailure("probe_failure", String(describing: error))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(response)
        FileHandle.standardOutput.write(data + Data([10]))
        if !response.ok { throw ExitCode.failure }
    }

    private func resolveConnection() throws -> (port: UInt16, token: String) {
        if let connection {
            guard port == nil else {
                throw ProbeFailure("invalid_arguments", "Choose --connection or --port, not both.")
            }
            let value = try ProbeConnection.load(from: connection)
            return (value.port, value.token)
        }
        guard let port else {
            throw ProbeFailure("invalid_arguments", "Provide --connection or --port.")
        }
        return (port, ProcessInfo.processInfo.environment["CONTROLKIT_PROBE_TOKEN"] ?? "")
    }

    private func validateOutput() throws {
        guard (operation == .screenshot) == (output != nil) else {
            throw ProbeFailure("invalid_arguments", "--output is required only for screenshot.")
        }
        if let output, FileManager.default.fileExists(atPath: output) {
            throw ProbeFailure("file_exists", "Screenshot output already exists.")
        }
    }

    private func saveScreenshot(_ response: inout ProbeResponse) throws {
        guard response.ok, operation == .screenshot else { return }
        guard let png = response.screenshotPNG, let output else {
            throw ProbeFailure("invalid_response", "Screenshot response has no PNG.")
        }
        let url = URL(fileURLWithPath: output)
        try png.write(to: url, options: [.withoutOverwriting])
        response.screenshotPNG = nil
        response.screenshotPath = url.path
    }
}
