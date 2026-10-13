import Foundation
import Testing

@testable import ControlKitDiscovery

final class DiscoveryFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ControlKitDiscovery-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try directory("")
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func directory(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func project(_ path: String = "App.xcodeproj") throws {
        try write("\(path)/project.pbxproj", "// Not parsed or validated by filesystem discovery.")
    }

    func workspace(_ path: String = "App.xcworkspace") throws {
        try write("\(path)/contents.xcworkspacedata", "<Workspace/>")
    }

    func buildServer(
        workspace: String? = "App.xcodeproj/project.xcworkspace", scheme: String? = "App"
    )
        throws
    {
        var value = ["name": "xcode build server", "kind": "xcode"]
        value["workspace"] = workspace
        value["scheme"] = scheme
        let data = try JSONSerialization.data(withJSONObject: value)
        try data.write(to: root.appendingPathComponent("buildServer.json"))
    }

    func resolve(_ customize: (inout DiscoveryOptions) -> Void = { _ in }) throws -> DiscoveryReport
    {
        var options = DiscoveryOptions()
        options.projectDirectory = root.path
        customize(&options)
        return try RepositoryDiscovery.resolve(options: options, currentDirectory: root)
    }
}

func expectFailure(_ code: DiscoveryFailure.Code, _ operation: () throws -> Void) {
    do {
        try operation()
        Issue.record("Expected discovery failure \(code.rawValue).")
    } catch let failure as DiscoveryFailure {
        #expect(failure.code == code)
    } catch {
        Issue.record("Unexpected error type \(type(of: error)).")
    }
}
