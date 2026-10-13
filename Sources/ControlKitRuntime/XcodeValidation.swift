import ControlKitDiscovery
import Foundation

package struct XcodeValidation: Codable, Sendable {
    package let toolchain: ToolchainIdentity
    package let scheme: String
    package let configuration: String
    package let validatedProjects: [String]
    package let validation: String

    package static func validate(
        _ report: DiscoveryReport, tools: AppleTools, budget suppliedBudget: OperationBudget? = nil,
        destination: String = "generic/platform=iOS Simulator"
    ) throws -> Self {
        guard report.readyForXcodeValidation, let container = report.container,
            let scheme = report.scheme?.value, let configuration = report.configuration?.value
        else { throw RuntimeFailure("configuration_missing", "Resolve filesystem choices first.") }
        let budget = suppliedBudget ?? OperationBudget(milliseconds: 30_000)
        let arguments = [
            container.kind == .project ? "-project" : "-workspace", container.path,
            "-disableAutomaticPackageResolution", "-onlyUsePackageVersionsFromResolvedFile",
        ]
        let listed = try tools.run(
            ["xcodebuild", "-list", "-json"] + arguments,
            milliseconds: 300_000, budget: budget, label: "xcode_scheme_list")
        let choices = try parseList(listed)
        try requireRuntime(
            choices.schemes.contains(scheme), "configuration_missing",
            "The selected scheme is not listed by Xcode.")
        let settings = try tools.run(
            [
                "xcodebuild", "-showBuildSettings", "-json", "-scheme", scheme,
                "-configuration", configuration, "-destination", destination,
            ] + arguments, milliseconds: 300_000, budget: budget,
            label: "xcode_build_settings")
        let projects = try projectPaths(settings, root: URL(fileURLWithPath: report.root))
        for path in projects {
            let data = try tools.run(
                [
                    "xcodebuild", "-list", "-json", "-project", path,
                    "-disableAutomaticPackageResolution", "-onlyUsePackageVersionsFromResolvedFile",
                ], milliseconds: 300_000, budget: budget,
                label: "xcode_project_configuration_list")
            try requireRuntime(
                try parseList(data).configurations.contains(configuration),
                "configuration_missing",
                "A participating Xcode project does not define this configuration.")
        }
        return Self(
            toolchain: tools.identity, scheme: scheme, configuration: configuration,
            validatedProjects: projects, validation: "xcode_build_settings")
    }

    struct Choices {
        let schemes: [String]
        let configurations: [String]
    }

    static func parseList(_ data: Data) throws -> Choices {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let scope = (root["project"] ?? root["workspace"]) as? [String: Any],
            let schemes = scope["schemes"] as? [String]
        else { throw RuntimeFailure("tool_output", "Unrecognized Xcode list output.") }
        let configurations = scope["configurations"] as? [String] ?? []
        try requireRuntime(
            schemes.count <= 512 && configurations.count <= 64,
            "resource_limit", "Xcode choices exceed supported bounds.")
        return Choices(schemes: schemes, configurations: configurations)
    }

    static func projectPaths(_ data: Data, root: URL) throws -> [String] {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw RuntimeFailure("tool_output", "Unrecognized Xcode build-settings output.")
        }
        try requireRuntime(
            !entries.isEmpty && entries.count <= 256,
            "resource_limit", "Unexpected number of Xcode targets.")
        var paths: Set<String> = []
        for entry in entries {
            guard let settings = entry["buildSettings"] as? [String: Any],
                let path = settings["PROJECT_FILE_PATH"] as? String
            else { throw RuntimeFailure("tool_output", "Missing participating project identity.") }
            let canonical = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            try requireRuntime(
                canonical.path.hasPrefix(root.path + "/")
                    && canonical.pathExtension == "xcodeproj",
                "configuration_invalid", "Participating Xcode project is outside the repository.")
            paths.insert(canonical.path)
            try requireRuntime(
                paths.count <= 16, "resource_limit", "Too many participating projects.")
        }
        return paths.sorted()
    }
}
