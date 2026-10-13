import ControlKitCore
import Foundation

package enum RepositoryDiscovery {
    package static func resolve(
        options: DiscoveryOptions, currentDirectory: URL
    ) throws -> DiscoveryReport {
        try resolve(
            options: options, currentDirectory: currentDirectory, now: DiscoveryBudget.systemTime())
    }

    static func resolve(
        options: DiscoveryOptions, currentDirectory: URL, now: @escaping () -> MonotonicInstant
    ) throws -> DiscoveryReport {
        let budget = try DiscoveryBudget(timeoutMilliseconds: options.timeoutMilliseconds, now: now)
        let files = DiscoveryFiles(budget: budget)
        let scope = try RepositoryScope.locate(
            options: options, currentDirectory: currentDirectory, files: files)
        var report = DiscoveryReport(root: scope.root.path, rootSource: scope.source)
        let layers = try ConfigurationLoader(scope: scope, files: files)
            .layers(options: options, report: &report)
        let containers = ContainerDiscovery(root: scope.root, files: files)
        report.container = try selectedContainer(layers, containers: containers)
        if report.container == nil {
            report.candidates = try containers.candidates()
            if report.candidates.count == 1 { report.container = report.candidates[0] }
        }
        report.scheme = try selectedValue(layers, key: \.scheme, name: "scheme")
        report.configuration = try selectedValue(
            layers, key: \.configuration, name: "configuration")
        if report.container == nil { report.requiredChoices.append("container") }
        if report.scheme == nil { report.requiredChoices.append("scheme") }
        if report.configuration == nil { report.requiredChoices.append("configuration") }
        try budget.check()
        return report
    }

    private static func selectedContainer(
        _ layers: [ConfigurationLayer], containers: ContainerDiscovery
    ) throws -> BuildContainer? {
        for layer in layers {
            if let workspace = layer.settings.workspace {
                return try containers.resolve(workspace, layer: layer, kind: .workspace)
            }
            if let project = layer.settings.xcodeProject {
                return try containers.resolve(project, layer: layer, kind: .project)
            }
        }
        return nil
    }

    private static func selectedValue(
        _ layers: [ConfigurationLayer], key: KeyPath<BuildSettings, String?>, name: String
    ) throws -> DiscoveredValue? {
        for layer in layers {
            if let value = layer.settings[keyPath: key] {
                try validateSetting(value, field: name)
                return DiscoveredValue(value: value, source: layer.source)
            }
        }
        return nil
    }
}
