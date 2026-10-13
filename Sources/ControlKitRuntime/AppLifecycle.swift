import ControlKitDiscovery
import CryptoKit
import Darwin
import Foundation

package struct AppArtifact: Codable, Sendable {
    package let path: String
    package let bundleIdentifier: String
    package let executable: String
    package let architectures: [String]
    package let platform: String
    package let target: String?
    package let configuration: String?
}

package struct BuildRequest: Sendable {
    package let report: DiscoveryReport
    package let product: String?
    package let destination: String

    package init(
        report: DiscoveryReport, product: String? = nil,
        destination: String = "generic/platform=iOS Simulator"
    ) {
        self.report = report
        self.product = product
        self.destination = destination
    }
}

package struct LaunchResult: Codable, Sendable {
    package let device: UUID
    package let bundleIdentifier: String
    package let processIdentifier: Int32
}

package final class AppLifecycle {
    private let tools: AppleTools
    private let simulators: SimulatorOperations

    package init(tools: AppleTools) throws {
        self.tools = tools
        simulators = try SimulatorOperations(tools: tools)
    }

    package func build(
        _ request: BuildRequest, budget suppliedBudget: OperationBudget? = nil
    ) throws -> AppArtifact {
        guard let container = request.report.container,
            let scheme = request.report.scheme?.value,
            let configuration = request.report.configuration?.value
        else { throw RuntimeFailure("configuration_missing", "Resolve build choices first.") }
        let budget = suppliedBudget ?? OperationBudget(milliseconds: 900_000)
        let cache = try buildCache(request: request, tools: tools, budget: budget)
        let lock = try FileLock(directory: cache.root, name: "build.lock")
        defer { withExtendedLifetime(lock) {} }
        _ = try XcodeValidation.validate(
            request.report, tools: tools, budget: budget, destination: request.destination)
        let arguments = [
            "xcodebuild", "-quiet", container.kind == .project ? "-project" : "-workspace",
            container.path,
            "-scheme", scheme, "-configuration", configuration,
            "-destination", request.destination,
            "-derivedDataPath", cache.derived.url.path, "-disableAutomaticPackageResolution",
            "-onlyUsePackageVersionsFromResolvedFile", "build",
        ]
        _ = try tools.run(
            arguments, milliseconds: 900_000, budget: budget,
            allowTruncatedDiagnostics: true, label: "xcode_build")
        _ = try RuntimeFiles.cacheBytes(
            cache.root.url, maximumBytes: 64 * 1_024 * 1_024 * 1_024,
            maximumEntries: 1_048_576, until: budget.end)
        let settings = try tools.run(
            [
                "xcodebuild", container.kind == .project ? "-project" : "-workspace",
                container.path,
                "-scheme", scheme, "-configuration", configuration,
                "-destination", request.destination,
                "-derivedDataPath", cache.derived.url.path,
                "-disableAutomaticPackageResolution", "-onlyUsePackageVersionsFromResolvedFile",
                "-showBuildSettings", "-json",
            ], milliseconds: 300_000, budget: budget,
            label: "xcode_product_settings")
        let candidate = try select(
            settings: settings, product: request.product, derived: cache.derived)
        return try inspect(
            path: candidate.path, target: candidate.target, configuration: configuration,
            budget: budget)
    }

    package func inspect(
        path: String, budget: OperationBudget? = nil
    ) throws -> AppArtifact {
        try inspect(path: path, target: nil, configuration: nil, budget: budget)
    }

    package func install(
        device id: UUID, artifact: AppArtifact, budget suppliedBudget: OperationBudget? = nil
    ) throws {
        let budget = suppliedBudget ?? OperationBudget(milliseconds: 300_000)
        let device = try simulators.device(id, budget: budget)
        try requireRuntime(device.state == "Booted", "device_not_booted", "Boot the device first.")
        let claim = try DeviceClaim(
            directory: simulators.leases, device: id, operation: "app.install")
        try claim.begin()
        _ = try tools.run(
            ["simctl", "install", id.uuidString, artifact.path],
            milliseconds: 300_000, budget: budget)
        let installed = try tools.run(
            ["simctl", "get_app_container", id.uuidString, artifact.bundleIdentifier, "app"],
            budget: budget)
        try requireRuntime(
            !installed.isEmpty, "outcome_unknown", "App installation could not be confirmed.")
        try claim.complete()
    }

    package func launch(
        device id: UUID, bundleIdentifier: String, budget suppliedBudget: OperationBudget? = nil
    ) throws -> LaunchResult {
        let budget = suppliedBudget ?? OperationBudget(milliseconds: 120_000)
        try validateRuntimeText(bundleIdentifier)
        let device = try simulators.device(id, budget: budget)
        try requireRuntime(device.state == "Booted", "device_not_booted", "Boot the device first.")
        let claim = try DeviceClaim(
            directory: simulators.leases, device: id, operation: "app.launch")
        try claim.begin()
        let data = try tools.run(
            ["simctl", "launch", id.uuidString, bundleIdentifier], budget: budget)
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard
            let pid = Int32(
                text.split(separator: ":").last?.trimmingCharacters(
                    in: .whitespaces) ?? "")
        else { throw RuntimeFailure("outcome_unknown", "App launch returned an unknown process.") }
        try claim.complete()
        return LaunchResult(device: id, bundleIdentifier: bundleIdentifier, processIdentifier: pid)
    }

    package func terminate(
        device id: UUID, bundleIdentifier: String, budget suppliedBudget: OperationBudget? = nil
    ) throws {
        let budget = suppliedBudget ?? OperationBudget(milliseconds: 120_000)
        try validateRuntimeText(bundleIdentifier)
        let device = try simulators.device(id, budget: budget)
        try requireRuntime(device.state == "Booted", "device_not_booted", "Boot the device first.")
        let claim = try DeviceClaim(
            directory: simulators.leases, device: id, operation: "app.terminate")
        try claim.begin()
        let result = try tools.start(
            ["simctl", "terminate", id.uuidString, bundleIdentifier],
            milliseconds: try budget.remaining(maximum: 120_000)
        ).wait()
        try requireRuntime(
            result.reason == .exited, "outcome_unknown",
            "App termination did not reach a known process exit.")
        // A nonzero simctl exit means the app was already absent or could not be found.
        // Both leave the explicit desired state (not running), with no mutation to replay.
        try claim.complete()
    }

    private struct BuildCache {
        let root: PrivateDirectory
        let derived: PrivateDirectory
    }

    private func buildCache(
        request: BuildRequest, tools: AppleTools, budget: OperationBudget
    ) throws -> BuildCache {
        let rootURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches/ControlKit-builds-v2", isDirectory: true)
        let root = try PrivateDirectory(rootURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var keyData = try encoder.encode(tools.identity)
        keyData.append(Data(request.report.root.utf8))
        keyData.append(Data((request.report.container?.path ?? "").utf8))
        keyData.append(Data((request.report.scheme?.value ?? "").utf8))
        keyData.append(Data((request.report.configuration?.value ?? "").utf8))
        keyData.append(Data(request.destination.utf8))
        let key = SHA256.hash(data: keyData).map { String(format: "%02x", $0) }.joined()
        let existing = try root.entries(limit: 16).filter { $0 != "build.lock" }
        try requireRuntime(
            existing.contains(key) || existing.count < 4,
            "resource_limit", "Build cache has four configurations; explicit cleanup is required.")
        let derived = try PrivateDirectory(rootURL.appendingPathComponent(key))
        _ = try RuntimeFiles.cacheBytes(
            rootURL, maximumBytes: 64 * 1_024 * 1_024 * 1_024,
            maximumEntries: 1_048_576, until: budget.end)
        return BuildCache(root: root, derived: derived)
    }

    private struct Candidate {
        let path: String
        let target: String
    }

    private func select(settings data: Data, product: String?, derived: PrivateDirectory) throws
        -> Candidate
    {
        guard let values = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
            !values.isEmpty, values.count <= 256
        else { throw RuntimeFailure("tool_output", "Unexpected Xcode build settings.") }
        var candidates: [Candidate] = []
        for value in values {
            guard let target = value["target"] as? String,
                let settings = value["buildSettings"] as? [String: Any]
            else { continue }
            guard settings["WRAPPER_EXTENSION"] as? String == "app",
                settings["PLATFORM_NAME"] as? String == "iphonesimulator",
                let directory = settings["TARGET_BUILD_DIR"] as? String,
                let name = settings["FULL_PRODUCT_NAME"] as? String
            else { continue }
            let matches =
                product == nil || product == target
                || product == settings["PRODUCT_NAME"] as? String
                || product == settings["PRODUCT_BUNDLE_IDENTIFIER"] as? String
            if matches {
                let path = URL(fileURLWithPath: directory).appendingPathComponent(name)
                    .standardizedFileURL.path
                try requireRuntime(
                    path.hasPrefix(derived.url.path + "/"), "configuration_invalid",
                    "Xcode product escaped the owned derived-data directory.")
                candidates.append(Candidate(path: path, target: target))
            }
        }
        try requireRuntime(
            !candidates.isEmpty, "product_missing", "No simulator app product found.")
        try requireRuntime(
            candidates.count == 1, "product_ambiguous",
            "More than one simulator app product matches; choose --product.")
        return candidates[0]
    }

    private func inspect(
        path: String, target: String?, configuration: String?, budget: OperationBudget?
    ) throws -> AppArtifact {
        let app = URL(fileURLWithPath: path).standardizedFileURL
        var info = stat()
        try requireRuntime(
            app.pathExtension == "app" && lstat(app.path, &info) == 0
                && info.st_mode & S_IFMT == S_IFDIR,
            "invalid_app", "App must be a non-symlink simulator .app directory.")
        let plistData = try RuntimeFiles.read(
            app.appendingPathComponent("Info.plist"), limit: 1_048_576)
        guard
            let plist = try PropertyListSerialization.propertyList(
                from: plistData, format: nil) as? [String: Any],
            let bundle = plist["CFBundleIdentifier"] as? String,
            let executable = plist["CFBundleExecutable"] as? String,
            plist["DTPlatformName"] as? String == "iphonesimulator",
            let platforms = plist["CFBundleSupportedPlatforms"] as? [String],
            platforms.contains("iPhoneSimulator")
        else { throw RuntimeFailure("invalid_app", "App metadata is not for an iOS simulator.") }
        try validateRuntimeText(bundle)
        try validateRuntimeText(executable)
        let executableURL = app.appendingPathComponent(executable)
        try requireRuntime(
            lstat(executableURL.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG,
            "invalid_app", "App executable must be a non-symlink regular file.")
        let architectureData = try tools.run(
            ["lipo", "-archs", executableURL.path], budget: budget,
            label: "app_architecture_check")
        let architectures = String(decoding: architectureData, as: UTF8.self)
            .split(whereSeparator: \.isWhitespace).map(String.init)
        try requireRuntime(
            !architectures.isEmpty && architectures.count <= 8,
            "invalid_app", "App executable architectures are unavailable.")
        #if arch(arm64)
            try requireRuntime(
                architectures.contains("arm64"), "invalid_app",
                "Simulator app does not contain the host arm64 architecture.")
        #elseif arch(x86_64)
            try requireRuntime(
                architectures.contains("x86_64"), "invalid_app",
                "Simulator app does not contain the host x86_64 architecture.")
        #endif
        return AppArtifact(
            path: app.path, bundleIdentifier: bundle, executable: executableURL.path,
            architectures: architectures, platform: "iphonesimulator",
            target: target, configuration: configuration)
    }
}
