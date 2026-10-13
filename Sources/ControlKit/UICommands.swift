import ArgumentParser
import ControlKitSupervisor
import ControlKitWire
import Foundation

struct UISessionArguments: ParsableArguments {
    @Option(help: "Session UUID.") var session: String
    @Option(help: "Positive helper generation returned by session start/status.") var generation:
        UInt64
    @Option(
        name: .customLong("request-id"), help: "Caller-chosen UUID; duplicates never reexecute.")
    var requestId: String?

    func apply(_ request: inout SupervisorRequest) throws {
        guard let id = UUID(uuidString: session), generation > 0 else {
            throw ValidationError("Invalid session or generation.")
        }
        request.sessionId = id
        request.helperGeneration = generation
        if let requestId {
            guard let value = UUID(uuidString: requestId) else {
                throw ValidationError("Invalid request UUID.")
            }
            request.requestId = value
        }
    }
}

struct SelectorArguments: ParsableArguments {
    @Option(name: .customLong("id"), help: "Exact accessibility identifier.") var identifier:
        String?
    @Option(help: "Exact accessibility label; optionally combine with --type.") var label: String?
    @Option(help: "Numeric XCUI element type; may be an exact selector.") var type: UInt?
    @Option(name: .customLong("ref"), help: "Element reference from --snapshot.") var reference:
        String?
    @Option(help: "Snapshot UUID required by --ref or coordinates.") var snapshot: String?
    @Option(help: "Finite screen-point x coordinate; requires --y and --snapshot.") var x: Double?
    @Option(help: "Finite screen-point y coordinate; requires --x and --snapshot.") var y: Double?

    func value() throws -> UISelector {
        var selector = UISelector()
        selector.identifier = identifier
        selector.label = label
        selector.elementType = type
        selector.reference = reference
        selector.x = x
        selector.y = y
        if let snapshot {
            guard let id = UUID(uuidString: snapshot) else {
                throw ValidationError("Invalid snapshot UUID.")
            }
            selector.snapshotId = id
        }
        do { try selector.validate() } catch {
            throw ValidationError("Choose exactly one valid selector family.")
        }
        return selector
    }
}

func uiRequest(
    operation: String, session: UISessionArguments, parameters: UIParameters?,
    outputPath: String? = nil, milliseconds: UInt64
) throws -> SupervisorRequest {
    var request = try SupervisorCLI.request(operation, milliseconds: milliseconds)
    try session.apply(&request)
    request.parameters = parameters
    request.output = outputPath
    return request
}

struct UI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ui", abstract: "Observe and interact through an owned session.",
        discussion: """
            Commands are serialized per simulator. Mutations are never automatically retried.
            A timeout/disconnect after dispatch returns outcome_unknown and fences the session.
            """,
        subcommands: [
            UIInspect.self, UIFind.self, UIScreenshot.self, UITap.self, UIType.self, UISetText.self,
            UISwipe.self, UIScroll.self, UIWait.self, UISystemAlert.self,
        ])
}

struct UIInspect: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect", abstract: "Capture one bounded accessibility snapshot.",
        discussion: """
            Returns at most 512 nodes, depth 32 and 2 MiB with explicit truncation reasons.
            Example: ControlKit ui inspect --session <uuid> --generation 1 --json
            """)
    @OptionGroup var session: UISessionArguments
    @Flag(help: "Also capture a separately timestamped screenshot.") var screenshot = false
    @Option(
        name: [.customLong("output"), .customLong("output-path")],
        help: "New PNG path; requires --screenshot and never overwrites.")
    var outputPath: String?
    @OptionGroup var output: OutputOptions

    mutating func run() throws {
        guard screenshot || outputPath == nil else {
            throw ValidationError("--output-path requires --screenshot.")
        }
        var parameters = UIParameters()
        parameters.includeScreenshot = screenshot
        let request = try uiRequest(
            operation: "ui.inspect", session: session, parameters: parameters,
            outputPath: outputPath,
            milliseconds: output.milliseconds(default: 30, maximum: 120))
        try SupervisorCLI.perform(request, json: output.json)
    }
}

struct UIScreenshot: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot", abstract: "Capture bounded PNG artifact metadata and bytes.",
        discussion:
            "Example: ControlKit ui screenshot --session <uuid> --generation 1 --output screen.png")
    @OptionGroup var session: UISessionArguments
    @Option(
        name: [.customLong("output"), .customLong("output-path")],
        help: "Optional new PNG export path; never overwrites.")
    var outputPath: String?
    @OptionGroup var output: OutputOptions

    mutating func run() throws {
        let request = try uiRequest(
            operation: "ui.screenshot", session: session, parameters: UIParameters(),
            outputPath: outputPath,
            milliseconds: output.milliseconds(default: 30, maximum: 120))
        try SupervisorCLI.perform(request, json: output.json)
    }
}

struct UITap: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tap", abstract: "Tap exactly one element or snapshot-grounded screen point.",
        discussion: "Example: ControlKit ui tap --session <uuid> --generation 1 --id submit")
    @OptionGroup var session: UISessionArguments
    @OptionGroup var selector: SelectorArguments
    @Flag(help: "Fault test: disconnect after executing, before replying; fences the session.")
    var faultDisconnectAfterDispatch = false
    @OptionGroup var output: OutputOptions

    mutating func run() throws {
        var parameters = UIParameters()
        parameters.selector = try selector.value()
        parameters.faultDisconnectAfterDispatch = faultDisconnectAfterDispatch
        try SupervisorCLI.perform(
            uiRequest(
                operation: "ui.tap", session: session, parameters: parameters,
                milliseconds: output.milliseconds(default: 30, maximum: 120)),
            json: output.json)
    }
}

struct UIType: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "type", abstract: "Append literal text to an explicitly selected text field.",
        discussion:
            "Example: ControlKit ui type --session <uuid> --generation 1 --id email --text a@b.com")
    @OptionGroup var session: UISessionArguments
    @OptionGroup var selector: SelectorArguments
    @Option(help: "Literal UTF-8 text to append, maximum 16 KiB.") var text: String?
    @Flag(
        help: "Read UTF-8 text from stdin, maximum 16 KiB. Mutually exclusive with --text.")
    var textStdin = false
    @OptionGroup var output: OutputOptions

    mutating func run() throws {
        let value = try textInput(text, stdin: textStdin, allowEmpty: false)
        var parameters = UIParameters()
        parameters.selector = try selector.value()
        parameters.text = value
        try SupervisorCLI.perform(
            uiRequest(
                operation: "ui.type", session: session, parameters: parameters,
                milliseconds: output.milliseconds(default: 30, maximum: 120)),
            json: output.json)
    }
}

func textInput(_ text: String?, stdin: Bool, allowEmpty: Bool) throws -> String {
    guard (text != nil) != stdin else {
        throw ValidationError("Choose exactly one of --text or --text-stdin.")
    }
    let value: String
    if let text {
        value = text
    } else {
        let data = try FileHandle.standardInput.read(upToCount: 16_385) ?? Data()
        guard data.count <= 16_384, let decoded = String(data: data, encoding: .utf8) else {
            throw ValidationError("stdin text must be UTF-8 and at most 16 KiB.")
        }
        value = decoded
    }
    guard allowEmpty || !value.isEmpty else {
        throw ValidationError("Text to append must not be empty.")
    }
    return value
}

struct GestureArguments: ParsableArguments {
    @OptionGroup var session: UISessionArguments
    @OptionGroup var selector: SelectorArguments
    @Option(help: "Direction: up, down, left or right.") var direction: String
    @OptionGroup var output: OutputOptions
}

struct UISwipe: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swipe", abstract: "Perform one bounded finger-motion gesture.",
        discussion: "Direction names finger motion. Example: ControlKit ui swipe ... --direction up"
    )
    @OptionGroup var values: GestureArguments

    mutating func run() throws { try gesture("ui.swipe", values) }
}

struct UIScroll: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scroll", abstract: "Perform one bounded content-direction scroll.",
        discussion:
            "Direction names content motion. Example: ControlKit ui scroll ... --direction down"
    )
    @OptionGroup var values: GestureArguments

    mutating func run() throws { try gesture("ui.scroll", values) }
}

func gesture(_ operation: String, _ values: GestureArguments) throws {
    var parameters = UIParameters()
    parameters.selector = try values.selector.value()
    parameters.direction = values.direction
    try SupervisorCLI.perform(
        uiRequest(
            operation: operation, session: values.session, parameters: parameters,
            milliseconds: values.output.milliseconds(default: 30, maximum: 120)),
        json: values.output.json)
}

struct UIWait: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wait", abstract: "Poll a bounded condition every 200 ms.",
        discussion: "States: exists, absent, hittable. Maximum 60 seconds and 300 samples.")
    @OptionGroup var session: UISessionArguments
    @OptionGroup var selector: SelectorArguments
    @Option(help: "Condition: exists, absent, or hittable.") var state: String
    @OptionGroup var output: OutputOptions

    mutating func run() throws {
        var parameters = UIParameters()
        parameters.selector = try selector.value()
        parameters.waitState = state
        try SupervisorCLI.perform(
            uiRequest(
                operation: "ui.wait", session: session, parameters: parameters,
                milliseconds: output.milliseconds(default: 10, minimum: 0.2, maximum: 60)),
            json: output.json)
    }
}
