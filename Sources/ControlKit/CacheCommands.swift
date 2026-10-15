import ArgumentParser
import ControlKitSupervisor
import Foundation

struct Cache: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cache", abstract: "Inspect and clean ControlKit's owned build caches.",
        discussion: """
            ControlKit keeps at most four app-build configurations and four helper builds.
            When a command reports that a cache is full or incomplete, clean it.
            """,
        subcommands: [CacheClean.self])
}

struct CacheClean: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clean", abstract: "Remove cached app and helper builds.",
        discussion: """
            Removes every entry under ~/Library/Caches/ControlKit-builds-v2 and
            ~/Library/Caches/ControlKit-session-helper-v1. The next build or session rebuilds
            what it needs. Refuses while a session is live or a build is running. Never touches
            simulators, apps, app data, or session ownership records.
            Example: ControlKit cache clean --dry-run
            """)
    @Flag(help: "List entries and sizes without removing anything.")
    var dryRun = false
    @OptionGroup var requestIdentity: CommandRequestIdentity
    @OptionGroup var output: OutputOptions

    mutating func run() throws {
        var request = try SupervisorCLI.request(
            dryRun ? "cache.plan" : "cache.clean",
            milliseconds: output.milliseconds(default: 300, maximum: 1_800))
        try requestIdentity.apply(&request)
        try SupervisorCLI.perform(request, json: output.json)
    }
}
