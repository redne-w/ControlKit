import ArgumentParser
import ControlKitSupervisor
import Foundation

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Diagnose exact Xcode, simulators, and repository metadata.",
        discussion: """
            Read-oriented diagnosis.
            It never accepts licenses, downloads runtimes, or writes config.
            Example: ControlKit doctor --project . --json
            """)
    @OptionGroup var build: BuildArguments
    @OptionGroup var requestIdentity: CommandRequestIdentity
    @OptionGroup var output: OutputOptions

    mutating func run() throws {
        var request = try SupervisorCLI.request(
            "doctor", milliseconds: output.milliseconds(default: 30, maximum: 60))
        request.management = try build.parameters()
        try requestIdentity.apply(&request)
        try SupervisorCLI.perform(request, json: output.json)
    }
}

struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Plan or explicitly write bounded shared ControlKit settings.",
        discussion: """
            Canonical buildServer.json remains preferred. With --write, only explicit missing
            settings are placed in controlkit.json; credentials/device state are never written.
            Interactive writes require confirmation. --non-interactive never prompts and requires
            --yes. Existing controlkit.json requires --replace-existing.

            Example:
              ControlKit setup --project . --profile-name backend \
                --configuration Debug --write
            """)
    @OptionGroup var build: BuildArguments
    @Option(help: "Profile name to write; default is 'default'.") var profileName: String?
    @Flag(help: "Write controlkit.json after validation; otherwise return a plan.") var write =
        false
    @Flag(help: "Explicitly replace an existing regular controlkit.json.") var replaceExisting =
        false
    @Flag(help: "Confirm a requested write, required with --non-interactive.") var yes = false
    @OptionGroup var requestIdentity: CommandRequestIdentity
    @OptionGroup var output: OutputOptions

    mutating func run() throws {
        let neverPrompt = output.nonInteractive || output.json
        if neverPrompt, write, !yes {
            throw ValidationError("Noninteractive/JSON --write requires --yes.")
        }
        if write, !neverPrompt { try promptForMissingSettings() }
        if write, !neverPrompt, !yes {
            print("Write shared controlkit.json? Type 'yes' to continue:", terminator: " ")
            guard readLine()?.lowercased() == "yes" else {
                throw ValidationError("Setup write was not confirmed.")
            }
        }
        var request = try SupervisorCLI.request(
            "setup", milliseconds: output.milliseconds(default: 30, maximum: 60))
        var values = try build.parameters()
        values.setupProfile = profileName
        values.write = write
        values.replaceExisting = replaceExisting
        request.management = values
        try requestIdentity.apply(&request)
        try SupervisorCLI.perform(request, json: output.json)
    }

    private mutating func promptForMissingSettings() throws {
        if build.workspace == nil, build.xcodeProject == nil {
            print("Xcode project/workspace path (empty reuses buildServer.json):", terminator: " ")
            if let value = readLine(), !value.isEmpty {
                if value.hasSuffix(".xcworkspace") {
                    build.workspace = value
                } else if value.hasSuffix(".xcodeproj") {
                    build.xcodeProject = value
                } else {
                    throw ValidationError("Container must end in .xcworkspace or .xcodeproj.")
                }
            }
        }
        if build.scheme == nil {
            print("Scheme (empty reuses buildServer.json):", terminator: " ")
            build.scheme = readLine().flatMap { $0.isEmpty ? nil : $0 }
        }
        if build.buildConfiguration == nil {
            print("Build configuration (empty leaves it unresolved):", terminator: " ")
            build.buildConfiguration = readLine().flatMap { $0.isEmpty ? nil : $0 }
        }
    }
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Build or validate, boot, install, launch, and start a session.",
        discussion: """
            Requires an explicit simulator.
            Build scripts in the selected repository are trusted code.
            Existing --app-path skips build. Completed steps are returned if a later step fails.

            Example:
              ControlKit run --project . --scheme App --configuration Debug \
                --device <udid> --json
            """)
    @OptionGroup var build: BuildArguments
    @OptionGroup var target: ProductionDevice
    @Option(help: "Existing simulator .app; skips repository build.") var appPath: String?
    @OptionGroup var requestIdentity: CommandRequestIdentity
    @OptionGroup var output: OutputOptions

    mutating func run() throws {
        var request = try SupervisorCLI.request(
            "run", milliseconds: output.milliseconds(default: 1_800, maximum: 1_800))
        request.device = try target.value()
        var values = try build.parameters()
        if let appPath {
            values.path = URL(fileURLWithPath: appPath).standardizedFileURL.path
        }
        request.management = values
        try requestIdentity.apply(&request)
        try SupervisorCLI.perform(request, json: output.json)
    }
}

struct Logs: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs", abstract: "Return bounded redacted supervisor events for one session.",
        discussion: """
            This snapshot does not follow indefinitely and never includes launch credentials.
            Example: ControlKit logs --session <uuid> --json
            """)
    @OptionGroup var identity: SessionIdentity
    @OptionGroup var requestIdentity: CommandRequestIdentity
    @OptionGroup var output: OutputOptions

    mutating func run() throws {
        var request = try SupervisorCLI.request(
            "logs", milliseconds: output.milliseconds(default: 5, maximum: 30))
        request.sessionId = try identity.id()
        try requestIdentity.apply(&request)
        try SupervisorCLI.perform(request, json: output.json)
    }
}
