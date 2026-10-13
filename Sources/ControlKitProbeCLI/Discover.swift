import ArgumentParser
import ControlKitDiscovery
import ControlKitRuntime
import Foundation

struct Discover: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Resolve repository build metadata without running any tools or writing files.",
        discussion: """
            Experimental JSON output, not the final doctor/setup command contract.
            Precedence: explicit options, selected controlkit.json profile, buildServer.json,
            then an unambiguous filesystem container. Never executes build-server argv.
            No Xcode scheme/configuration validation yet; success means metadata is complete.
            Missing choices and ambiguity print a report and exit nonzero.
            Without --project, searches up to the nearest Git root (or uses the current
            directory outside Git). Relative explicit container paths are rooted there.
            Filesystem calls cannot be interrupted; --timeout is checked between calls.

            Examples:
              ControlKit probe discover --project . --scheme App --configuration Debug
              ControlKit probe discover --profile backend
              ControlKit probe discover --project . --xcode-project App.xcodeproj
            """
    )

    @Option(help: "Repository directory and discovery boundary. Default: nearest Git root.")
    var project: String?
    @Option(
        help: "controlkit.json profile. Default: defaultProfile; never chooses the first profile.")
    var profile: String?
    @Option(help: "Workspace path. Mutually exclusive with --xcode-project.")
    var workspace: String?
    @Option(help: "Xcode project path. Mutually exclusive with --workspace.")
    var xcodeProject: String?
    @Option(help: "Scheme name. No implicit latest-built or first scheme.")
    var scheme: String?
    @Option(
        name: .customLong("configuration"), help: "Build configuration name; no implicit default.")
    var buildConfiguration: String?
    @Option(help: "Cooperative discovery deadline in seconds, 0.001–30.")
    var timeout: Double = 5
    @Flag(
        help:
            "Validate resolved choices with bounded Xcode tools (30 seconds; may update caches)."
    )
    var validateXcode = false

    private struct Response: Encodable {
        var ok = false
        var report: DiscoveryReport?
        var error: DiscoveryFailure?
        var xcode: XcodeValidation?
    }

    mutating func run() throws {
        var response = Response()
        do {
            guard timeout.isFinite, (0.001...30).contains(timeout) else {
                throw DiscoveryFailure(.invalidConfiguration, "Timeout must be 0.001–30 seconds.")
            }
            var options = DiscoveryOptions()
            options.projectDirectory = project
            options.profile = profile
            options.workspace = workspace
            options.xcodeProject = xcodeProject
            options.scheme = scheme
            options.configuration = buildConfiguration
            options.timeoutMilliseconds = UInt64(timeout * 1_000)
            let report = try RepositoryDiscovery.resolve(
                options: options,
                currentDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            response.report = report
            response.error = report.failure
            response.ok = report.readyForXcodeValidation
            if validateXcode, response.ok {
                let cancellation = CancellationSignal()
                let tools = try AppleTools(cancellation: cancellation)
                response.xcode = try XcodeValidation.validate(report, tools: tools)
            }
        } catch {
            response.ok = false
            response.error =
                error as? DiscoveryFailure
                ?? DiscoveryFailure(
                    .invalidConfiguration,
                    (error as? RuntimeFailure)?.message ?? "Repository validation failed.")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try encoder.encode(response) + Data([10]))
        if !response.ok { throw ExitCode.failure }
    }
}
