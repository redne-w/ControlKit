import ArgumentParser
import ControlKitProbeCLI
import ControlKitRuntime
import ControlKitSupervisor
import Foundation

@main
struct ControlKit: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ControlKit",
        abstract: "Native iOS simulator automation for engineers and agents.",
        discussion: """
            Build, boot, install, launch and attach with 'ControlKit run'.
            Use 'ControlKit doctor' and 'ControlKit setup' for repository and toolchain preparation.
            Use 'ControlKit help session' and 'ControlKit help ui' for automation and recovery.
            If something goes wrong, run 'ControlKit report' and send the archive it prints.
            Local diagnostics: ~/Library/Logs/ControlKit
            """,
        version: ControlKitVersion.description,
        subcommands: [
            ProbeCommand.self, Sim.self, App.self, Sessions.self, UI.self,
            Doctor.self, Setup.self, Run.self, Logs.self, Cache.self, Report.self,
            InternalSupervisor.self,
        ]
    )

    /// Mirrors ArgumentParser's synchronous entry point and adds one start and one finish
    /// record, so a bug report shows each invocation, its exit status, and its failure text.
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let started = ContinuousClock.now
        DiagnosticLog.record(
            "process.started",
            [
                "arguments": DiagnosticLog.sanitize(arguments: arguments),
                "workingDirectory": FileManager.default.currentDirectoryPath,
            ])
        do {
            var command = try parseAsRoot(arguments)
            try command.run()
            finished(started: started, status: 0, error: nil)
        } catch {
            finished(started: started, status: exitCode(for: error).rawValue, error: error)
            exit(withError: error)
        }
    }

    private static func finished(
        started: ContinuousClock.Instant, status: Int32, error: (any Error)?
    ) {
        let elapsed = started.duration(to: .now).components
        var fields = [
            "exitStatus": "\(status)",
            "milliseconds":
                "\(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000)",
        ]
        if let error, status != 0 {
            let message = fullMessage(for: error)
            if !message.isEmpty { fields["message"] = message }
            fields["error"] = DiagnosticLog.describe(error)
        }
        DiagnosticLog.record("process.finished", fields)
    }
}
