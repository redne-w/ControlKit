import Foundation
import Testing

@testable import ControlKitRuntime
@testable import ControlKitSupervisor

struct SupervisorProtocolTests {
    @Test func envelopeIdentitiesAndCompletion() throws {
        let toolchain = ToolchainIdentity(
            developerDirectory: "/Xcode", xcodeVersion: "27", xcodeBuild: "A",
            simulatorSDKBuild: "B")
        let request = SupervisorRequest(
            operation: "session.list", toolchain: toolchain, remainingMilliseconds: 5_000)
        let epoch = UUID()
        let response = SupervisorResponse(
            request: request, epoch: epoch, completion: .finished, data: SupervisorData())
        #expect(response.ok)
        #expect(response.requestId == request.requestId)
        #expect(response.supervisorEpoch == epoch)
        #expect(response.error == nil)
        let encoded = try JSONEncoder().encode(response)
        let possible = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        let object = try #require(possible)
        #expect(object.keys.count == 9)
        #expect(object["sessionId"] is NSNull)
        #expect(object["error"] is NSNull)
    }

    @Test func localSocketChecksPeerAndFrames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try PrivateDirectory(root)
        let listener = try LocalListener(directory: directory)
        let client = try LocalListener.connect(directory: directory)
        let possible = try listener.accept(milliseconds: 1_000)
        let accepted = try #require(possible)
        defer {
            client.close()
            accepted.close()
        }
        let toolchain = ToolchainIdentity(
            developerDirectory: "/Xcode", xcodeVersion: "27", xcodeBuild: "A",
            simulatorSDKBuild: "B")
        let request = SupervisorRequest(
            operation: "session.list", toolchain: toolchain, remainingMilliseconds: 5_000)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        try client.sendJSON(request, limit: 65_536, until: deadline)
        let received = try accepted.receiveJSON(
            SupervisorRequest.self, limit: 65_536, until: deadline)
        #expect(received.requestId == request.requestId)
    }

    @Test func artifactPublicationIsAtomicAndNoClobber() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("screen.png")
        let data = Data(repeating: 7, count: 128)
        try ArtifactExport.write(data, to: output.path)
        #expect(try Data(contentsOf: output) == data)
        #expect(throws: RuntimeFailure.self) {
            try ArtifactExport.write(Data(), to: output.path)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["screen.png"])
    }

    @Test func artifactParentCanonicalizesMacOSTemporarySymlinks() throws {
        let destination = URL(fileURLWithPath: "/private/tmp/controlkit-test.png")
        #expect(try ArtifactExport.canonicalParent(destination).path == "/private/tmp")
    }

    @Test func requestDecoderRejectsUnknownFields() throws {
        let toolchain = ToolchainIdentity(
            developerDirectory: "/Xcode", xcodeVersion: "27", xcodeBuild: "A",
            simulatorSDKBuild: "B")
        let request = SupervisorRequest(
            operation: "session.list", toolchain: toolchain, remainingMilliseconds: 5_000)
        let encoded = try JSONEncoder().encode(request)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["unknown"] = true
        let invalid = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(SupervisorRequest.self, from: invalid)
        }
    }

    @Test func configurationWriterIsAtomicAndRequiresExplicitReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("controlkit.json")
        try ConfigurationWriter.write(Data("first".utf8), to: file, replace: false)
        #expect(throws: RuntimeFailure.self) {
            try ConfigurationWriter.write(Data("second".utf8), to: file, replace: false)
        }
        try ConfigurationWriter.write(Data("second".utf8), to: file, replace: true)
        #expect(try Data(contentsOf: file) == Data("second".utf8))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: root.path) == ["controlkit.json"])
    }
}
