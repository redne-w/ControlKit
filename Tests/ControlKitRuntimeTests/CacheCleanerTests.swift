import Darwin
import Foundation
import Testing

@testable import ControlKitRuntime

struct CacheCleanerTests {
    private func makeCache(_ root: URL, entries: [String]) throws -> CacheCleaner.Root {
        let directory = try PrivateDirectory(root)
        for entry in entries {
            let nested = root.appendingPathComponent(entry).appendingPathComponent("Build/x")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 8_192).write(to: nested.appendingPathComponent("o"))
        }
        _ = directory
        return CacheCleaner.Root(name: root.lastPathComponent, url: root)
    }

    private var deadline: ContinuousClock.Instant { .now.advanced(by: .seconds(30)) }

    @Test func dryRunReportsWithoutRemovingAndCleanRemovesEverything() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let apps = try makeCache(base.appendingPathComponent("apps"), entries: ["a", "b"])
        let helpers = try makeCache(base.appendingPathComponent("helpers"), entries: ["h"])
        let missing = CacheCleaner.Root(name: "missing", url: base.appendingPathComponent("none"))

        let plan = try CacheCleaner.clean(
            [apps, helpers, missing], dryRun: true, until: deadline)
        #expect(plan.dryRun)
        #expect(plan.entries.map(\.key).sorted() == ["a", "b", "h"])
        #expect(plan.freedBytes >= 3 * 8_192)
        #expect(FileManager.default.fileExists(atPath: apps.url.appendingPathComponent("a").path))

        let cleaned = try CacheCleaner.clean(
            [apps, helpers, missing], dryRun: false, until: deadline)
        #expect(cleaned.entries.count == 3)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: apps.url.path) == ["build.lock"])
        #expect(!FileManager.default.fileExists(atPath: missing.url.path))
    }

    @Test func symlinksAreUnlinkedNotFollowed() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: outside.appendingPathComponent("keep"))
        let cache = try makeCache(base.appendingPathComponent("cache"), entries: ["a"])
        try FileManager.default.createSymbolicLink(
            at: cache.url.appendingPathComponent("a/link"), withDestinationURL: outside)

        _ = try CacheCleaner.clean([cache], dryRun: false, until: deadline)
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("keep").path))
        #expect(!FileManager.default.fileExists(atPath: cache.url.appendingPathComponent("a").path))
    }

    @Test func runningBuildOrLiveSessionRefusesWithoutRemoving() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let cache = try makeCache(base.appendingPathComponent("cache"), entries: ["a"])
        let entry = cache.url.appendingPathComponent("a").path

        let building = try FileLock(directory: try PrivateDirectory(cache.url), name: "build.lock")
        #expect(throws: RuntimeFailure("device_busy", "Another operation owns this resource.")) {
            _ = try CacheCleaner.clean([cache], dryRun: false, until: deadline)
        }
        withExtendedLifetime(building) {}
        #expect(FileManager.default.fileExists(atPath: entry))

        #expect(throws: RuntimeFailure.self) {
            _ = try CacheCleaner.clean(
                [cache], dryRun: false, until: deadline,
                beforeRemoval: { throw RuntimeFailure("device_busy", "live session") })
        }
        #expect(FileManager.default.fileExists(atPath: entry))
    }
}
