import ControlKitProcess
import Foundation

package struct ToolchainIdentity: Codable, Equatable, Sendable {
    package let developerDirectory: String
    package let xcodeVersion: String
    package let xcodeBuild: String
    package let simulatorSDKBuild: String
}

package final class AppleTools {
    package let identity: ToolchainIdentity
    let environment: [String: String]
    let cancellation: CancellationSignal?

    package init(
        environment inherited: [String: String] = ProcessInfo.processInfo.environment,
        cancellation: CancellationSignal? = nil, budget suppliedBudget: OperationBudget? = nil
    ) throws {
        self.cancellation = cancellation
        let budget = suppliedBudget ?? OperationBudget(milliseconds: 30_000)
        var environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "TMPDIR": NSTemporaryDirectory(),
            "LC_ALL": "en_US.UTF-8",
        ]
        let developer: String
        if let selected = inherited["DEVELOPER_DIR"] {
            try validateRuntimeText(selected)
            developer = URL(fileURLWithPath: selected).resolvingSymlinksInPath().path
        } else {
            developer = try Self.text(
                executable: "/usr/bin/xcode-select", arguments: ["-p"], environment: environment,
                budget: budget, cancellation: cancellation)
        }
        environment["DEVELOPER_DIR"] = developer
        let version = try Self.text(
            arguments: ["xcodebuild", "-version"], environment: environment,
            budget: budget, cancellation: cancellation
        ).split(separator: "\n")
        try requireRuntime(
            version.count == 2 && version[0].hasPrefix("Xcode ")
                && version[1].hasPrefix("Build version "),
            "unsupported_toolchain", "Unexpected Xcode version output.")
        let sdk = try Self.text(
            arguments: ["--sdk", "iphonesimulator", "--show-sdk-build-version"],
            environment: environment, budget: budget, cancellation: cancellation)
        self.environment = environment
        identity = ToolchainIdentity(
            developerDirectory: developer, xcodeVersion: String(version[0].dropFirst(6)),
            xcodeBuild: String(version[1].dropFirst(14)), simulatorSDKBuild: sdk)
    }

    package func start(
        _ arguments: [String], directory: String = "/", milliseconds: UInt64,
        outputLimit: Int = 8_388_608
    ) throws -> OwnedProcess {
        try OwnedProcess(
            ProcessCommand(
                executable: "/usr/bin/xcrun", arguments: arguments, environment: environment,
                directory: directory, timeoutMilliseconds: milliseconds, outputLimit: outputLimit),
            cancellation: { [cancellation] in cancellation?.isRequested ?? false })
    }

    package func run(
        _ arguments: [String], milliseconds: UInt64 = 30_000, budget: OperationBudget? = nil,
        allowTruncatedDiagnostics: Bool = false, label: String = "apple_tool"
    ) throws -> Data {
        let remaining = try budget?.remaining(maximum: milliseconds) ?? milliseconds
        let result = try start(arguments, milliseconds: remaining).wait()
        do {
            try Self.validate(result, allowTruncatedDiagnostics: allowTruncatedDiagnostics)
        } catch let failure as RuntimeFailure {
            throw RuntimeFailure(failure.code, "\(label): \(failure.message)")
        }
        return result.stdout
    }

    private static func text(
        executable: String = "/usr/bin/xcrun", arguments: [String], environment: [String: String],
        budget: OperationBudget, cancellation: CancellationSignal?
    ) throws -> String {
        let result = try OwnedProcess(
            ProcessCommand(
                executable: executable, arguments: arguments, environment: environment,
                directory: "/",
                timeoutMilliseconds: try budget.remaining(maximum: 30_000), outputLimit: 65_536),
            cancellation: { cancellation?.isRequested ?? false }
        ).wait()
        try validate(result)
        guard let text = String(data: result.stdout, encoding: .utf8) else {
            throw RuntimeFailure("tool_output", "Invalid tool output encoding.")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func validate(_ result: ProcessResult, allowTruncatedDiagnostics: Bool = false) throws {
        try requireRuntime(
            result.reason == .exited, "outcome_unknown",
            "Tool did not finish before cancellation/deadline; do not replay its effects.")
        try requireRuntime(
            result.succeeded, "tool_failed", "Apple tool returned a nonzero exit status.")
        try requireRuntime(
            !result.outputTruncated || allowTruncatedDiagnostics,
            "resource_limit", "Apple tool output exceeded its limit.")
    }
}
