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
        var info = stat()
        try #require(stat(root.appendingPathComponent("data").path, &info) == 0)
        let allocated = UInt64(info.st_blocks) * 512
        #expect(allocated >= 100)
        #expect(try RuntimeFiles.cacheBytes(root, maximumBytes: allocated) == allocated)
        #expect(throws: RuntimeFailure.self) {
            _ = try RuntimeFiles.cacheBytes(root, maximumBytes: allocated - 1)
        }
    }

    /// Xcode's compilation cache preallocates sparse files with huge apparent sizes.
    @Test func sparseFilesCountAllocatedBytesOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try PrivateDirectory(root)
        try directory.write("sparse", data: Data())
        let file = open(root.appendingPathComponent("sparse").path, O_WRONLY)
        try #require(file >= 0)
        defer { close(file) }
        try #require(ftruncate(file, 8 * 1_024 * 1_024 * 1_024) == 0)
        #expect(try RuntimeFiles.cacheBytes(root, maximumBytes: 1_024 * 1_024) <= 1_024 * 1_024)
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
