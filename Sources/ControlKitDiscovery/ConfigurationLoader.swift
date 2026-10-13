import Foundation

struct ConfigurationLoader {
    let scope: RepositoryScope
    let files: DiscoveryFiles

    func layers(options: DiscoveryOptions, report: inout DiscoveryReport) throws
        -> [ConfigurationLayer]
    {
        var layers = [
            ConfigurationLayer(
                settings: BuildSettings(
                    workspace: options.workspace, xcodeProject: options.xcodeProject,
                    scheme: options.scheme, configuration: options.configuration),
                source: Provenance(kind: .explicit, file: nil, profile: nil), directory: scope.root)
        ]
        if let profile = try profileLayer(options: options, report: &report) {
            layers.append(profile)
        }
        if let buildServer = try buildServerLayer(report: &report) { layers.append(buildServer) }
        for layer in layers
        where layer.settings.workspace != nil && layer.settings.xcodeProject != nil {
            throw DiscoveryFailure(
                .invalidConfiguration, "Choose workspace or xcodeProject in each layer, not both.")
        }
        return layers
    }

    private func profileLayer(options: DiscoveryOptions, report: inout DiscoveryReport) throws
        -> ConfigurationLayer?
    {
        guard let file = try scope.configurationFile("controlkit.json", files: files) else {
            if options.profile != nil {
                throw DiscoveryFailure(
                    .configurationMissing, "Requested profile requires controlkit.json.")
            }
            return nil
        }
        report.controlkitFile = file.path
        let config = try ConfigurationJSON.decode(
            ControlKitConfiguration.self, data: files.read(file))
        try config.validate()
        report.availableProfiles = config.profiles.keys.sorted()
        guard let name = options.profile ?? config.defaultProfile else {
            if !config.profiles.isEmpty { report.requiredChoices.append("profile") }
            return nil
        }
        try validateSetting(name, field: "profile name", limit: 128)
        guard let settings = config.profiles[name] else {
            throw DiscoveryFailure(
                .configurationMissing, "Selected profile is not in controlkit.json.")
        }
        report.selectedProfile = name
        return ConfigurationLayer(
            settings: settings, source: Provenance(kind: .profile, file: file.path, profile: name),
            directory: file.deletingLastPathComponent())
    }

    private func buildServerLayer(report: inout DiscoveryReport) throws -> ConfigurationLayer? {
        guard let file = try scope.configurationFile("buildServer.json", files: files) else {
            return nil
        }
        report.buildServerFile = file.path
        let data = try files.read(file)
        let header = try ConfigurationJSON.decode(BuildServerHeader.self, data: data)
        guard header.name == "xcode build server", header.kind == "xcode" else {
            report.findings.append(
                DiscoveryFinding(
                    code: "unsupported_build_server",
                    message: "Only xcode-build-server kind=xcode supplies build settings.",
                    file: file.path))
            return nil
        }
        let config = try ConfigurationJSON.decode(BuildServerSettings.self, data: data)
        return ConfigurationLayer(
            settings: BuildSettings(workspace: config.workspace, scheme: config.scheme),
            source: Provenance(kind: .buildServer, file: file.path, profile: nil),
            directory: file.deletingLastPathComponent())
    }
}
