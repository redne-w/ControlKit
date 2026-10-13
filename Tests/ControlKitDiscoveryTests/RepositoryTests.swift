import Darwin
import Foundation
import Testing

@testable import ControlKitDiscovery

struct RepositoryTests {
    @Test func nearestConfigurationWithinGitBoundaryUsesOwningDirectory() throws {
        let fixture = try DiscoveryFixture()
        try fixture.directory(".git")
        let child = try fixture.directory("apps/mobile/src")
        try fixture.project("apps/mobile/App.xcodeproj")
        try fixture.write(
            "apps/mobile/buildServer.json",
            """
            {"name":"xcode build server","kind":"xcode",
             "workspace":"App.xcodeproj/project.xcworkspace","scheme":"Mobile"}
            """)
        try fixture.write(
            "controlkit.json",
            """
            {"schemaVersion":1,"defaultProfile":"dev",
             "profiles":{"dev":{"configuration":"Debug"}}}
            """)
        let report = try RepositoryDiscovery.resolve(
            options: DiscoveryOptions(), currentDirectory: child)
        #expect(report.root == fixture.root.path)
        #expect(report.rootSource == "git")
        #expect(report.container?.path.hasSuffix("/apps/mobile/App.xcodeproj") == true)
        #expect(report.scheme?.value == "Mobile")
        #expect(report.configuration?.source.file?.hasSuffix("/controlkit.json") == true)
        #expect(report.readyForXcodeValidation)
    }

    @Test func gitWorktreeFileStopsSearchAndExplicitRootDoesNotInherit() throws {
        let fixture = try DiscoveryFixture()
        try fixture.write("buildServer.json", "not JSON")
        try fixture.write("child/.git", "gitdir: ignored; discovery does not execute Git")
        try fixture.project("child/App.xcodeproj")
        let child = fixture.root.appendingPathComponent("child", isDirectory: true)
        let report = try RepositoryDiscovery.resolve(
            options: DiscoveryOptions(), currentDirectory: child)
        #expect(report.root == child.path)
        #expect(report.buildServerFile == nil)
        var options = DiscoveryOptions()
        options.projectDirectory = child.path
        let explicit = try RepositoryDiscovery.resolve(
            options: options, currentDirectory: fixture.root)
        #expect(explicit.rootSource == "explicit")
        #expect(explicit.buildServerFile == nil)
    }

    @Test func outsideGitUsesStartingDirectoryNotAncestorMetadata() throws {
        let fixture = try DiscoveryFixture()
        try fixture.write("buildServer.json", "not JSON")
        let child = try fixture.directory("child")
        try fixture.project("child/App.xcodeproj")
        let report = try RepositoryDiscovery.resolve(
            options: DiscoveryOptions(), currentDirectory: child)
        #expect(report.root == child.path)
        #expect(report.rootSource == "working_directory")
        #expect(report.container != nil)
        #expect(report.buildServerFile == nil)
    }

    @Test func ambiguityIsSortedAndEmbeddedWorkspacesAreNotCandidates() throws {
        let fixture = try DiscoveryFixture()
        try fixture.project("Z.xcodeproj")
        try fixture.workspace("Z.xcodeproj/project.xcworkspace")
        try fixture.workspace("A.xcworkspace")
        let report = try fixture.resolve()
        #expect(report.container == nil)
        #expect(
            report.candidates.map { URL(fileURLWithPath: $0.path).lastPathComponent }
                == ["A.xcworkspace", "Z.xcodeproj"])
        #expect(report.failure?.code == .configurationAmbiguous)
    }

    @Test func excludedDirectoriesAndSymlinksDoNotSupplyCandidates() throws {
        let fixture = try DiscoveryFixture()
        for parent in [
            ".git", ".build", ".delta", ".hidden", "DerivedData", "Pods", "Carthage",
            "node_modules",
        ] {
            try fixture.project("\(parent)/Other.xcodeproj")
        }
        try fixture.project()
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("Alias.xcodeproj"),
            withDestinationURL: fixture.root.appendingPathComponent("App.xcodeproj"))
        let report = try fixture.resolve()
        #expect(report.candidates.count == 1)
        #expect(report.container?.path.hasSuffix("/App.xcodeproj") == true)
        expectFailure(.invalidConfiguration) {
            _ = try fixture.resolve { $0.xcodeProject = "Alias.xcodeproj" }
        }
    }

    @Test func configurationSymlinksAndFIFOsFailWithoutBlocking() throws {
        let fixture = try DiscoveryFixture()
        try fixture.write("actual.json", "{}")
        let config = fixture.root.appendingPathComponent("buildServer.json")
        try FileManager.default.createSymbolicLink(
            at: config, withDestinationURL: fixture.root.appendingPathComponent("actual.json"))
        expectFailure(.filesystemError) { _ = try fixture.resolve() }
        try FileManager.default.removeItem(at: config)
        #expect(mkfifo(config.path, 0o600) == 0)
        expectFailure(.filesystemError) { _ = try fixture.resolve() }
    }

    @Test func missingMarkersAndSymlinkAncestorsAreStaleNotFallback() throws {
        let fixture = try DiscoveryFixture()
        try fixture.directory("Broken.xcodeproj")
        expectFailure(.invalidConfiguration) { _ = try fixture.resolve() }
        try fixture.project("real/App.xcodeproj")
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("alias"),
            withDestinationURL: fixture.root.appendingPathComponent("real"))
        expectFailure(.invalidConfiguration) {
            _ = try fixture.resolve { $0.xcodeProject = "alias/App.xcodeproj" }
        }
        expectFailure(.invalidConfiguration) {
            _ = try fixture.resolve { $0.xcodeProject = "../Other.xcodeproj" }
        }
    }
}
