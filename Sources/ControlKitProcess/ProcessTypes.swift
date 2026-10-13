import Foundation

package struct ProcessFailure: Error, Equatable, Sendable {
    package enum Code: String, Codable, Sendable {
        case invalidInput, cancelledBeforeSpawn, spawnFailed, observationFailed, cleanupUnconfirmed
    }
    package let code: Code
    package init(_ code: Code) { self.code = code }
}

package struct ProcessCommand: Sendable {
    package let executable: String
    package let arguments: [String]
    package let environment: [String: String]
    package let directory: String
    package let timeoutMilliseconds: UInt64
    package let outputLimit: Int

    package init(
        executable: String, arguments: [String], environment: [String: String],
        directory: String, timeoutMilliseconds: UInt64, outputLimit: Int = 8 * 1_024 * 1_024
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.directory = directory
        self.timeoutMilliseconds = timeoutMilliseconds
        self.outputLimit = outputLimit
    }

    func validate() throws {
        let strings =
            [executable, directory] + arguments
            + environment.map { "\($0.key)=\($0.value)" }
        guard executable.hasPrefix("/"), directory.hasPrefix("/"), arguments.count <= 128,
            environment.count <= 128, (1...1_800_000).contains(timeoutMilliseconds),
            (0...8 * 1_024 * 1_024).contains(outputLimit),
            strings.allSatisfy({ $0.utf8.count <= 16_384 && !$0.utf8.contains(0) }),
            strings.reduce(0, { $0 + $1.utf8.count + 1 }) <= 65_536,
            environment.keys.allSatisfy({ !$0.isEmpty && !$0.contains("=") })
        else { throw ProcessFailure(.invalidInput) }
    }
}

package struct ProcessResult: Sendable {
    package enum Reason: String, Codable, Sendable {
        case exited, timedOut, cancelled, ioFailure
    }
    package let reason: Reason
    package let exitCode: Int32?
    package let signal: Int32?
    package let stdout: Data
    package let stderr: Data
    package let outputTruncated: Bool

    package var succeeded: Bool {
        reason == .exited && exitCode == 0 && signal == nil
    }
}
