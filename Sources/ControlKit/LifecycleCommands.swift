import ArgumentParser
import ControlKitSupervisor
import Foundation

struct ProductionDevice: ParsableArguments {
    @Option(help: "Explicit simulator UDID.")
    var device: String

    func value() throws -> UUID {
        guard let id = UUID(uuidString: device) else {
            throw ValidationError("Invalid simulator UDID.")
        }
        return id
    }
}

struct BuildArguments: ParsableArguments {
    @Option(help: "Explicit repository/discovery boundary.")
    var project: String?
    @Option(help: "Selected controlkit.json profile.")
    var profile: String?
    @Option(help: "Workspace override; mutually exclusive with --xcode-project.")
    var workspace: String?
    @Option(help: "Xcode project override; mutually exclusive with --workspace.")
    var xcodeProject: String?
    @Option(help: "Scheme override.")
    var scheme: String?
    @Option(name: .customLong("configuration"), help: "Build configuration override.")
    var buildConfiguration: String?
    @Option(help: "Target, product, or bundle identifier when multiple apps build.")
    var product: String?

    func parameters() throws -> ManagementParameters {
        guard workspace == nil || xcodeProject == nil else {
            throw ValidationError("Choose --workspace or --xcode-project, not both.")
        }
        let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .standardizedFileURL.resolvingSymlinksInPath()
        var values = ManagementParameters()
        values.workingDirectory = current.path
        if let project {
            values.projectDirectory =
                URL(fileURLWithPath: project, relativeTo: current)
                .standardizedFileURL.resolvingSymlinksInPath().path
        }
        values.profile = profile
        values.workspace = workspace
        values.xcodeProject = xcodeProject
        values.scheme = scheme
        values.configuration = buildConfiguration
        values.product = product
        return values
    }
}

struct Sim: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sim", abstract: "List and manage explicitly selected iOS simulators.",
        discussion:
            "Mutations share the session device lease and never choose a current simulator.",
        subcommands: [
            SimListCommand.self, SimCreateCommand.self,
            SimBootCommand.self, SimShutdownCommand.self,
        ])
}

struct SimListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list", abstract: "List bounded available simulator inventory.")
    @OptionGroup var requestIdentity: CommandRequestIdentity
    @OptionGroup var output: OutputOptions

    mutating func run() throws {
        var request = try SupervisorCLI.request(
            "sim.list", milliseconds: output.milliseconds(default: 30, maximum: 30))
        try requestIdentity.apply(&request)
        try SupervisorCLI.perform(request, json: output.json)
    }
}

struct SimCreateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create one simulator from exact runtime/device identifiers.",
        discussion: """
            Example: ControlKit sim create --name Agent \
              --runtime com.apple.CoreSimulator.SimRuntime.iOS-26-4 \
              --device-type com.apple.CoreSimulator.SimDeviceType.iPhone-17 --json
            """)
    @Option var name: String
    @Option var runtime: String
    @Option var deviceType: String
    @OptionGroup var requestIdentity: CommandRequestIdentity
    @OptionGroup var output: OutputOptions

    mutating func run() throws {
        var request = try SupervisorCLI.request(
            "sim.create", milliseconds: output.milliseconds(default: 30, maximum: 60))
        var values = ManagementParameters()
        values.name = name
        values.runtime = runtime
        values.deviceType = deviceType
        request.management = values
        try requestIdentity.apply(&request)
        try SupervisorCLI.perform(request, json: output.json)
    }
}

struct SimBootCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "boot", abstract: "Boot one simulator and wait for readiness.",
        discussion: "Already booted is success. Example: ControlKit sim boot --device <udid> --json"
    )
    @OptionGroup var target: ProductionDevice
    @OptionGroup var requestIdentity: CommandRequestIdentity
    @OptionGroup var output: OutputOptions

    mutating func run() throws {
        var request = try SupervisorCLI.request(
            "sim.boot", milliseconds: output.milliseconds(default: 120, maximum: 300))
        request.device = try target.value()
        try requestIdentity.apply(&request)
        try SupervisorCLI.perform(request, json: output.json)
    }
}

struct SimShutdownCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shutdown", abstract: "Shut down one unleased simulator; preserve its data.")
    @OptionGroup var target: ProductionDevice
    @OptionGroup var requestIdentity: CommandRequestIdentity
    @OptionGroup var output: OutputOptions

    mutating func run() throws {
        var request = try SupervisorCLI.request(
            "sim.shutdown", milliseconds: output.milliseconds(default: 120, maximum: 300))
        request.device = try target.value()
        try requestIdentity.apply(&request)
        try SupervisorCLI.perform(request, json: output.json)
    }
}

struct App: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app", abstract: "Build, manage, and diagnose simulator apps.",
        discussion: """
            Builds may execute trusted repository build scripts.
            Install and launch never reset app data.
            """,
        subcommands: [
            AppBuild.self, AppInstall.self, AppLaunch.self, AppTerminate.self,
            AppLogs.self, AppCrashes.self,
        ])
}

struct AppBuild: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build", abstract: "Build one validated simulator .app in owned derived data.",
        discussion:
            "Example: ControlKit app build --project . --scheme App --configuration Debug --json")
    @OptionGroup var build: BuildArguments
    @Option(help: "Optional simulator UDID used as the Xcode build destination.")
    var device: String?
    @OptionGroup var requestIdentity: CommandRequestIdentity
    @OptionGroup var output: OutputOptions

    mutating func run() throws {
        var request = try SupervisorCLI.request(
            "app.build", milliseconds: output.milliseconds(default: 900, maximum: 1_800))
        request.management = try build.parameters()
        if let device {
            guard let id = UUID(uuidString: device) else {
                throw ValidationError("Invalid simulator UDID.")
            }
            request.device = id
        }
        try requestIdentity.apply(&request)
        try SupervisorCLI.perform(request, json: output.json)
    }
}

struct AppInstall: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install", abstract: "Validate and install one existing simulator .app.",
        discussion: "May replace/terminate an installed app; never clears its data.")
    @OptionGroup var target: ProductionDevice
    @Option(help: "Existing simulator .app path.") var path: String
    @OptionGroup var requestIdentity: CommandRequestIdentity
    @OptionGroup var output: OutputOptions

    mutating func run() throws {
        var request = try SupervisorCLI.request(
            "app.install", milliseconds: output.milliseconds(default: 60, maximum: 300))
        request.device = try target.value()
        var values = ManagementParameters()
        values.path = URL(fileURLWithPath: path).standardizedFileURL.path
        request.management = values
        try requestIdentity.apply(&request)
        try SupervisorCLI.perform(request, json: output.json)
    }
}

struct AppLaunch: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "launch",
        abstract: "Launch or activate an installed app without resetting data.")
    @OptionGroup var target: ProductionDevice
    @Option(help: "Installed app bundle identifier.") var bundleId: String
    @OptionGroup var requestIdentity: CommandRequestIdentity
    @OptionGroup var output: OutputOptions

    mutating func run() throws {
        var request = try SupervisorCLI.request(
            "app.launch", milliseconds: output.milliseconds(default: 30, maximum: 120))
        request.device = try target.value()
        var values = ManagementParameters()
        values.bundleIdentifier = bundleId
        request.management = values
        try requestIdentity.apply(&request)
        try SupervisorCLI.perform(request, json: output.json)
    }
}

struct AppTerminate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "terminate", abstract: "Explicitly terminate an app; preserve data/simulator.")
    @OptionGroup var target: ProductionDevice
    @Option(help: "Installed app bundle identifier.") var bundleId: String
    @OptionGroup var requestIdentity: CommandRequestIdentity
    @OptionGroup var output: OutputOptions

    mutating func run() throws {
        var request = try SupervisorCLI.request(
            "app.terminate", milliseconds: output.milliseconds(default: 30, maximum: 120))
        request.device = try target.value()
        var values = ManagementParameters()
        values.bundleIdentifier = bundleId
        request.management = values
        try requestIdentity.apply(&request)
        try SupervisorCLI.perform(request, json: output.json)
    }
}

struct AppLogs: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs", abstract: "Read bounded recent logs for one installed app.",
        discussion:
            "Scopes by the bundle's resolved executable name; reports that association explicitly.")
    @OptionGroup var target: ProductionDevice
    @Option(help: "Exact installed app bundle identifier.") var bundleId: String
    @Option(help: "Recent seconds (default 60, maximum 3600).") var since = 60
    @Option(help: "Maximum entries (default 200, maximum 512).") var limit = 200
    @OptionGroup var requestIdentity: CommandRequestIdentity
    @OptionGroup var output: OutputOptions

    mutating func run() throws {
        guard (1...3_600).contains(since), (1...512).contains(limit) else {
            throw ValidationError("Logs --since/--limit are outside supported bounds.")
        }
        var request = try SupervisorCLI.request(
            "app.logs", milliseconds: output.milliseconds(default: 60, maximum: 120))
        request.device = try target.value()
        var values = ManagementParameters()
        values.bundleIdentifier = bundleId
        values.sinceSeconds = since
        values.limit = limit
        request.management = values
        try requestIdentity.apply(&request)
        try SupervisorCLI.perform(request, json: output.json)
    }
}

struct AppCrashes: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "crashes", abstract: "Read bounded crash reports for one installed app.",
        discussion: "Requires an exact simulator association in structured crash data.")
    @OptionGroup var target: ProductionDevice
    @Option(help: "Exact installed app bundle identifier.") var bundleId: String
    @Option(help: "Recent seconds (default 3600, maximum 86400).") var since = 3_600
    @Option(help: "Maximum reports (default 10, maximum 32).") var limit = 10
    @OptionGroup var requestIdentity: CommandRequestIdentity
    @OptionGroup var output: OutputOptions

    mutating func run() throws {
        guard (1...86_400).contains(since), (1...32).contains(limit) else {
            throw ValidationError("Crashes --since/--limit are outside supported bounds.")
        }
        var request = try SupervisorCLI.request(
            "app.crashes", milliseconds: output.milliseconds(default: 30, maximum: 60))
        request.device = try target.value()
        var values = ManagementParameters()
        values.bundleIdentifier = bundleId
        values.sinceSeconds = since
        values.limit = limit
        request.management = values
        try requestIdentity.apply(&request)
        try SupervisorCLI.perform(request, json: output.json)
    }
}
