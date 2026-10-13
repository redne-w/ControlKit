import Foundation
import Testing

@testable import ControlKitRuntime

struct XcodeValidationTests {
    @Test func projectAndWorkspaceChoices() throws {
        let project = Data(
            #"{"project":{"schemes":["App"],"configurations":["Debug","Release"]}}"#.utf8)
        #expect(try XcodeValidation.parseList(project).configurations == ["Debug", "Release"])
        let workspace = Data(#"{"workspace":{"schemes":["App"]}}"#.utf8)
        #expect(try XcodeValidation.parseList(workspace).configurations.isEmpty)
        #expect(throws: RuntimeFailure.self) { _ = try XcodeValidation.parseList(Data("{}".utf8)) }
    }

    @Test func schemeLimitCoversLargeRepositoriesButRemainsBounded() throws {
        for count in [512, 513] {
            let object = ["project": ["schemes": (0..<count).map { "Scheme-\($0)" }]]
            let data = try JSONSerialization.data(withJSONObject: object)
            if count == 512 {
                #expect(try XcodeValidation.parseList(data).schemes.count == count)
            } else {
                #expect(throws: RuntimeFailure.self) {
                    _ = try XcodeValidation.parseList(data)
                }
            }
        }
    }

    @Test func participatingProjectsAreBoundedAndConfined() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let path = root.appendingPathComponent("App.xcodeproj").path
        let data = try JSONSerialization.data(withJSONObject: [
            ["buildSettings": ["PROJECT_FILE_PATH": path]],
            ["buildSettings": ["PROJECT_FILE_PATH": path]],
        ])
        #expect(try XcodeValidation.projectPaths(data, root: root) == [path])
        let outside = Data(
            #"[{"buildSettings":{"PROJECT_FILE_PATH":"/outside/App.xcodeproj"}}]"#.utf8)
        #expect(throws: RuntimeFailure.self) {
            _ = try XcodeValidation.projectPaths(outside, root: root)
        }
    }
}
