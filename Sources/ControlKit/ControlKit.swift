import ArgumentParser
import ControlKitProbeCLI
import ControlKitSupervisor

@main
struct ControlKit: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ControlKit",
        abstract: "Native iOS simulator automation for engineers and agents.",
        discussion: """
            Build, boot, install, launch and attach with 'ControlKit run'.
            Use 'ControlKit doctor' and 'ControlKit setup' for repository and toolchain preparation.
            Use 'ControlKit help session' and 'ControlKit help ui' for automation and recovery.
            """,
        subcommands: [
            ProbeCommand.self, Sim.self, App.self, Sessions.self, UI.self,
            Doctor.self, Setup.self, Run.self, Logs.self, InternalSupervisor.self,
        ]
    )
}
