import Foundation

struct RepositoryScope {
    let root: URL
    let source: String
    let configurationDirectories: [URL]

    static func locate(
        options: DiscoveryOptions, currentDirectory: URL, files: DiscoveryFiles
    ) throws -> Self {
        if let path = options.projectDirectory {
            try validateSetting(path, field: "project directory")
            let root = URL(fileURLWithPath: path, relativeTo: currentDirectory)
                .standardizedFileURL.resolvingSymlinksInPath()
            guard try files.kind(root) == .directory else { throw files.failure(root) }
            return Self(root: root, source: "explicit", configurationDirectories: [root])
        }
        let start = currentDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard try files.kind(start) == .directory else { throw files.failure(start) }
        var directories: [URL] = []
        var directory = start
        for _ in 0..<DiscoveryLimits.ancestors {
            try files.budget.check()
            directories.append(directory)
            let marker = directory.appendingPathComponent(".git")
            if let kind = try files.kind(marker) {
                guard kind == .directory || kind == .regular else { throw files.failure(marker) }
                return Self(root: directory, source: "git", configurationDirectories: directories)
            }
            if directory.path == "/" {
                return Self(
                    root: start, source: "working_directory", configurationDirectories: [start])
            }
            directory = directory.deletingLastPathComponent()
        }
        throw DiscoveryFailure(.resourceLimit, "Repository root search exceeds 32 ancestor steps.")
    }

    func configurationFile(_ name: String, files: DiscoveryFiles) throws -> URL? {
        for directory in configurationDirectories {
            // Listing, rather than fileExists, preserves canonical spelling on insensitive volumes.
            if try files.entries(directory).contains(name) {
                return directory.appendingPathComponent(name)
            }
        }
        return nil
    }
}
