import Foundation
import Testing

@testable import ControlKitRuntime

struct HelperCacheTests {
    @Test func keyIncludesEveryOwnedSourceAndExactToolchain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for path in HelperCache.inputs {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(path.utf8).write(to: file)
        }
        let identity = ToolchainIdentity(
            developerDirectory: "/Xcode", xcodeVersion: "27", xcodeBuild: "A",
            simulatorSDKBuild: "B")
        let original = try HelperCache.fingerprint(source: root, identity: identity)
        #expect(original.count == 64)
        #expect(try HelperCache.fingerprint(source: root, identity: identity) == original)
        for path in HelperCache.inputs {
            let file = root.appendingPathComponent(path)
            try Data((path + " changed").utf8).write(to: file)
            #expect(try HelperCache.fingerprint(source: root, identity: identity) != original)
            try Data(path.utf8).write(to: file)
        }
        let changed = ToolchainIdentity(
            developerDirectory: "/OtherXcode", xcodeVersion: "27", xcodeBuild: "A",
            simulatorSDKBuild: "B")
        #expect(try HelperCache.fingerprint(source: root, identity: changed) != original)
    }

    @Test func retainedBytesCountFilesWithoutFollowingSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try PrivateDirectory(root)
        try directory.write("data", data: Data(repeating: 0, count: 100))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("outside"),
            withDestinationURL: URL(fileURLWithPath: "/"))
        #expect(try RuntimeFiles.cacheBytes(root, maximumBytes: 100) == 100)
        #expect(throws: RuntimeFailure.self) {
            _ = try RuntimeFiles.cacheBytes(root, maximumBytes: 99)
        }
    }

    @Test func cacheEntryBudgetIsConfigurableAndExact() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try PrivateDirectory(root)
        for index in 0..<3 {
            try directory.write("entry-\(index)", data: Data())
        }
        #expect(try RuntimeFiles.cacheBytes(root, maximumEntries: 3) == 0)
        try directory.write("entry-3", data: Data())
        #expect(throws: RuntimeFailure.self) {
            _ = try RuntimeFiles.cacheBytes(root, maximumEntries: 3)
        }
    }
}
