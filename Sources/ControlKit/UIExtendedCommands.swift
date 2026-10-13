import ArgumentParser
import ControlKitSupervisor
import ControlKitWire

struct UIFind: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "find",
        abstract: "Return bounded exact matches without choosing one.",
        discussion: """
            Returns at most 16 matches with references, frames and hittability.
            Type-only discovery is allowed. Coordinates and existing references are not.
            """)
    @OptionGroup var session: UISessionArguments
    @OptionGroup var selector: SelectorArguments
    @OptionGroup var output: OutputOptions

    mutating func run() throws {
        let selected = try selector.value()
        guard selected.reference == nil, selected.x == nil else {
            throw ValidationError("Find requires --id, --label, or --type.")
        }
        var parameters = UIParameters()
        parameters.selector = selected
        try SupervisorCLI.perform(
            uiRequest(
                operation: "ui.find", session: session, parameters: parameters,
                milliseconds: output.milliseconds(default: 30, maximum: 120)),
            json: output.json)
    }
}

struct UISetText: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set-text",
        abstract: "Replace one nonsecure text field's complete value.",
        discussion: """
            Existing content is cleared first. The nonempty final value is verified before success.
            Snapshot-grounded coordinates may focus an unlabeled field.
            """)
    @OptionGroup var session: UISessionArguments
    @OptionGroup var selector: SelectorArguments
    @Option(help: "Final literal UTF-8 value, maximum 16 KiB.") var text: String?
    @Flag(
        help: "Read the final UTF-8 value from stdin, maximum 16 KiB.")
    var textStdin = false
    @OptionGroup var output: OutputOptions

    mutating func run() throws {
        let value = try textInput(text, stdin: textStdin, allowEmpty: false)
        var parameters = UIParameters()
        parameters.selector = try selector.value()
        parameters.text = value
        try SupervisorCLI.perform(
            uiRequest(
                operation: "ui.set_text", session: session, parameters: parameters,
                milliseconds: output.milliseconds(default: 30, maximum: 120)),
            json: output.json)
    }
}

struct UISystemAlert: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "system-alert",
        abstract: "Inspect or tap the foreground iOS system alert only.",
        subcommands: [UISystemAlertInspect.self, UISystemAlertTap.self])
}

struct UISystemAlertInspect: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Return one bounded SpringBoard alert and its buttons.")
    @OptionGroup var session: UISessionArguments
    @OptionGroup var output: OutputOptions

    mutating func run() throws {
        try SupervisorCLI.perform(
            uiRequest(
                operation: "ui.system_alert.inspect", session: session,
                parameters: UIParameters(),
                milliseconds: output.milliseconds(default: 10, maximum: 30)),
            json: output.json)
    }
}

struct SystemAlertSelectorArguments: ParsableArguments {
    @Option(name: .customLong("id"), help: "Exact system-alert button identifier.")
    var identifier: String?
    @Option(help: "Exact system-alert button label.") var label: String?

    func value() throws -> UISelector {
        var selector = UISelector()
        selector.identifier = identifier
        selector.label = label
        do { try selector.validateSystemAlert() } catch {
            throw ValidationError("Choose exactly one of --id or --label.")
        }
        return selector
    }
}

struct UISystemAlertTap: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tap",
        abstract: "Tap exactly one enabled and hittable system-alert button.")
    @OptionGroup var session: UISessionArguments
    @OptionGroup var selector: SystemAlertSelectorArguments
    @Flag(help: "Fault test: disconnect after executing, before replying; fences the session.")
    var faultDisconnectAfterDispatch = false
    @OptionGroup var output: OutputOptions

    mutating func run() throws {
        var parameters = UIParameters()
        parameters.selector = try selector.value()
        parameters.faultDisconnectAfterDispatch = faultDisconnectAfterDispatch
        try SupervisorCLI.perform(
            uiRequest(
                operation: "ui.system_alert.tap", session: session, parameters: parameters,
                milliseconds: output.milliseconds(default: 30, maximum: 120)),
            json: output.json)
    }
}
