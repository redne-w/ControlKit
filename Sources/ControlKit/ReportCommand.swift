import ArgumentParser
import ControlKitRuntime
import Foundation

struct Report: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "report",
        abstract: "Package local diagnostics into one archive to send to the ControlKit team.",
        discussion: """
            Collects ControlKit logs from ~/Library/Logs/ControlKit (events, the supervisor's
            standard error, and captured Apple tool failures), recent ControlKit crash reports,
            macOS/Xcode/simulator inventory, and 'ControlKit doctor' output for the current
            directory. Run it from the repository you were automating.

            Credentials, bearer tokens, URL user info and query strings, and typed UI text are
            removed, and your home directory is shown as ~. Project paths, scheme names, and
            build output remain so failures can be reproduced. Review the archive before sending
            it outside your team.

            Example: ControlKit report --output-directory ~/Desktop
            """)
    @Option(help: "Directory for the archive. Default: ~/Desktop, else the current directory.")
    var outputDirectory: String?
    @Flag(help: "Skip Xcode, simulator, and doctor commands; collect files only.")
    var filesOnly = false
    @Flag(help: "Emit {\"archive\": path} as JSON.")
    var json = false

    mutating func run() throws {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            throw ValidationError("Cannot resolve the running ControlKit executable.")
        }
        let working = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let archive: URL
        do {
            archive = try DiagnosticReport.create(
                DiagnosticReport.Inputs(
                    executable: executable, workingDirectory: working,
                    outputDirectory: try destination(working: working)),
                includeCommands: !filesOnly)
        } catch let failure as RuntimeFailure {
            throw ValidationError("\(failure.code): \(failure.message)")
        }
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(["archive": archive.path])
            FileHandle.standardOutput.write(data + Data([10]))
        } else {
            print("Wrote \(archive.path)")
            print("Send this file to the ControlKit team with a short description of the problem.")
        }
    }

    private func destination(working: URL) throws -> URL {
        var isDirectory: ObjCBool = false
        if let outputDirectory {
            let url = URL(fileURLWithPath: outputDirectory, isDirectory: true)
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else { throw ValidationError("Output directory does not exist: \(url.path)") }
            return url
        }
        let desktop = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Desktop", isDirectory: true)
        let hasDesktop = FileManager.default.fileExists(
            atPath: desktop.path, isDirectory: &isDirectory)
        return hasDesktop && isDirectory.boolValue ? desktop : working
    }
}
