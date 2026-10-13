import Foundation
import Testing

@testable import ControlKitDiscovery

struct ConfigurationTests {
    @Test func embeddedProjectWorkspaceAndMissingConfiguration() throws {
        let fixture = try DiscoveryFixture()
        try fixture.project()
        try fixture.buildServer()
        let report = try fixture.resolve()
        #expect(report.container?.kind == .project)
        #expect(report.container?.path == fixture.root.appendingPathComponent("App.xcodeproj").path)
        #expect(report.container?.source.kind == .buildServer)
        #expect(report.scheme?.value == "App")
        #expect(report.requiredChoices == ["configuration"])
        #expect(report.validation == "filesystem_only")
        #expect(report.failure?.code == .configurationMissing)
    }

    @Test func existingEmbeddedWorkspaceIsPreserved() throws {
        let fixture = try DiscoveryFixture()
        try fixture.project()
        try fixture.workspace("App.xcodeproj/project.xcworkspace")
        try fixture.buildServer()
        let report = try fixture.resolve()
        #expect(report.container?.kind == .workspace)
        #expect(
            report.container?.path
                == fixture.root.appendingPathComponent(
                    "App.xcodeproj/project.xcworkspace"
                ).path)
    }

    @Test func perFieldPrecedenceAndProvenance() throws {
        let fixture = try DiscoveryFixture()
        try fixture.project()
        try fixture.workspace("Override.xcworkspace")
        try fixture.buildServer()
        try fixture.write(
            "controlkit.json",
            """
            {"schemaVersion":1,"defaultProfile":"dev","profiles":{
              "dev":{"scheme":"ProfileScheme","configuration":"Debug"}
            }}
            """)
        let report = try fixture.resolve { $0.workspace = "Override.xcworkspace" }
        #expect(report.container?.kind == .workspace)
        #expect(report.container?.source.kind == .explicit)
        #expect(report.scheme?.value == "ProfileScheme")
        #expect(report.scheme?.source.profile == "dev")
        #expect(
            report.scheme?.source.file
                == fixture.root.appendingPathComponent("controlkit.json").path)
        #expect(report.configuration?.value == "Debug")
        #expect(report.readyForXcodeValidation)
        #expect(report.failure == nil)
        let explicit = try fixture.resolve {
            $0.scheme = "Explicit"
            $0.configuration = "Release"
        }
        #expect(explicit.scheme?.source.kind == .explicit)
        #expect(explicit.configuration?.value == "Release")
    }

    @Test func staleWinnerFailsButExplicitOverrideRepairsIt() throws {
        let fixture = try DiscoveryFixture()
        try fixture.project()
        try fixture.buildServer(workspace: "/another/checkout/App.xcodeproj/project.xcworkspace")
        expectFailure(.invalidConfiguration) { _ = try fixture.resolve() }
        let report = try fixture.resolve { $0.xcodeProject = "App.xcodeproj" }
        #expect(report.container?.source.kind == .explicit)
        #expect(report.scheme?.source.kind == .buildServer)
        try fixture.buildServer(workspace: "Missing.xcworkspace")
        expectFailure(.invalidConfiguration) { _ = try fixture.resolve() }
    }

    @Test func profileSelectionIsNeverImplicitFirst() throws {
        let fixture = try DiscoveryFixture()
        try fixture.project()
        try fixture.write(
            "controlkit.json", #"{"schemaVersion":1,"profiles":{"z":{},"a":{"scheme":"A"}}}"#)
        let missing = try fixture.resolve()
        #expect(missing.availableProfiles == ["a", "z"])
        #expect(missing.requiredChoices.contains("profile"))
        let selected = try fixture.resolve { $0.profile = "a" }
        #expect(selected.scheme?.value == "A")
        #expect(!selected.requiredChoices.contains("profile"))
        expectFailure(.configurationMissing) { _ = try fixture.resolve { $0.profile = "unknown" } }
        try fixture.write(
            "controlkit.json",
            #"{"schemaVersion":1,"defaultProfile":"z","profiles":{"z":{},"a":{}}}"#)
        #expect(try fixture.resolve { $0.profile = "a" }.selectedProfile == "a")
    }

    @Test func conflictingContainersAndMalformedConfigAreNotHidden() throws {
        let fixture = try DiscoveryFixture()
        try fixture.project()
        expectFailure(.invalidConfiguration) {
            _ = try fixture.resolve {
                $0.workspace = "A.xcworkspace"
                $0.xcodeProject = "App.xcodeproj"
            }
        }
        for text in [
            #"{"schemaVersion":2,"profiles":{}}"#,
            #"{"schemaVersion":1,"profiles":{},"typo":true}"#,
            #"{"schemaVersion":1,"profiles":{"dev":{"scheem":"App"}}}"#,
            #"{"schemaVersion":1,"profiles":null}"#,
            #"{"name":"xcode build server","kind":"xcode","scheme":5}"#,
        ] {
            let file = text.contains("schemaVersion") ? "controlkit.json" : "buildServer.json"
            try fixture.write(file, text)
            expectFailure(.invalidConfiguration) {
                _ = try fixture.resolve {
                    $0.xcodeProject = "App.xcodeproj"
                    $0.scheme = "App"
                }
            }
            try FileManager.default.removeItem(at: fixture.root.appendingPathComponent(file))
        }
    }

    @Test func onlyCanonicalBuildServerIsConsumed() throws {
        let fixture = try DiscoveryFixture()
        try fixture.project()
        try fixture.write("buildserver.json", "invalid JSON")
        let report = try fixture.resolve()
        #expect(report.buildServerFile == nil)
        #expect(report.container?.source.kind == .discovery)
        #expect(report.scheme == nil)
    }

    @Test func unsupportedProviderIsNotInterpretedAndMissingSchemeIsAChoice() throws {
        let fixture = try DiscoveryFixture()
        try fixture.project()
        try fixture.write(
            "buildServer.json",
            #"{"name":"other server","kind":"xcode","workspace":42,"scheme":"wrong"}"#)
        let report = try fixture.resolve()
        #expect(report.findings.map(\.code) == ["unsupported_build_server"])
        #expect(report.scheme == nil)
        try fixture.buildServer(workspace: nil, scheme: nil)
        let missing = try fixture.resolve()
        #expect(missing.container?.source.kind == .discovery)
        #expect(missing.requiredChoices == ["scheme", "configuration"])
    }

    @Test func argvAndBuildRootAreIgnoredAndNeverPrinted() throws {
        let fixture = try DiscoveryFixture()
        try fixture.project()
        let sentinel = fixture.root.appendingPathComponent("executed")
        let value: [String: Any] = [
            "name": "xcode build server", "kind": "xcode",
            "workspace": "App.xcodeproj/project.xcworkspace",
            "argv": ["/bin/sh", "-c", "touch '\(sentinel.path)'", "secret-value"],
            "build_root": "/secret-value",
        ]
        let data = try JSONSerialization.data(withJSONObject: value)
        try data.write(to: fixture.root.appendingPathComponent("buildServer.json"))
        let report = try fixture.resolve()
        let output = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        #expect(!output.contains("secret-value"))
        #expect(!FileManager.default.fileExists(atPath: sentinel.path))
    }
}
