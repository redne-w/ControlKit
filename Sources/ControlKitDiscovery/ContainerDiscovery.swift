import Foundation

struct ContainerDiscovery {
    let root: URL
    let files: DiscoveryFiles

    func resolve(_ path: String, layer: ConfigurationLayer, kind: BuildContainer.Kind) throws
        -> BuildContainer
    {
        try validateSetting(path, field: "container path")
        var url = URL(fileURLWithPath: path, relativeTo: layer.directory).standardizedFileURL
        var selectedKind = kind
        // xcode-build-server also emits this path as a project fallback when it is absent.
        // Preserve a real embedded workspace; only normalize a nonexistent one to its project.
        if layer.source.kind == .buildServer, url.lastPathComponent == "project.xcworkspace",
            url.deletingLastPathComponent().pathExtension == "xcodeproj",
            try files.kind(url.appendingPathComponent("contents.xcworkspacedata")) == nil
        {
            url.deleteLastPathComponent()
            selectedKind = .project
        }
        let suffix = selectedKind == .project ? "xcodeproj" : "xcworkspace"
        guard url.pathExtension == suffix else {
            throw DiscoveryFailure(.invalidConfiguration, "Container extension must be .\(suffix).")
        }
        try validatePath(url)
        let marker = url.appendingPathComponent(
            selectedKind == .project ? "project.pbxproj" : "contents.xcworkspacedata")
        guard try files.kind(marker) == .regular else {
            throw DiscoveryFailure(
                .invalidConfiguration, "Container is missing a regular \(marker.lastPathComponent)."
            )
        }
        return BuildContainer(kind: selectedKind, path: url.path, source: layer.source)
    }

    private func validatePath(_ url: URL) throws {
        let prefix = root.pathComponents
        let components = url.pathComponents
        guard components.starts(with: prefix), components.count > prefix.count else {
            throw DiscoveryFailure(
                .invalidConfiguration, "Container must be inside the repository root.")
        }
        var directory = root
        for component in components.dropFirst(prefix.count) {
            directory.appendPathComponent(component)
            guard try files.kind(directory) == .directory else {
                throw DiscoveryFailure(
                    .invalidConfiguration,
                    "Container path is missing, not a directory, or a symlink.")
            }
        }
    }

    func candidates() throws -> [BuildContainer] {
        var pending: [(URL, Int)] = [(root, 0)]
        var cursor = 0
        var result: [BuildContainer] = []
        let source = Provenance(kind: .discovery, file: nil, profile: nil)
        let layer = ConfigurationLayer(settings: BuildSettings(), source: source, directory: root)
        while cursor < pending.count {
            let (directory, depth) = pending[cursor]
            cursor += 1
            for name in try files.entries(directory) {
                if Self.excluded(name) { continue }
                let child = directory.appendingPathComponent(name)
                guard try files.kind(child) == .directory else { continue }
                guard depth < DiscoveryLimits.depth else {
                    throw DiscoveryFailure(
                        .resourceLimit,
                        "Container search exceeds depth 4; choose a container explicitly.")
                }
                if child.pathExtension == "xcodeproj" || child.pathExtension == "xcworkspace" {
                    let kind: BuildContainer.Kind =
                        child.pathExtension == "xcodeproj" ? .project : .workspace
                    result.append(try resolve(child.path, layer: layer, kind: kind))
                } else {
                    pending.append((child, depth + 1))
                }
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    private static func excluded(_ name: String) -> Bool {
        name.hasPrefix(".")
            || ["DerivedData", "Pods", "Carthage", "node_modules"].contains(name)
    }
}
