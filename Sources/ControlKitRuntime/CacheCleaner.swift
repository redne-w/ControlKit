import Darwin
import Foundation

package struct CacheEntryRemoval: Codable, Equatable, Sendable {
    package let cache: String
    package let key: String
    package let bytes: UInt64
}

package struct CacheCleanResult: Codable, Equatable, Sendable {
    package let dryRun: Bool
    package let entries: [CacheEntryRemoval]
    package let freedBytes: UInt64
}

/// Removes owned build-cache entries. Callers must ensure no session is using a helper build;
/// the per-cache build lock excludes concurrent builds and is held for the whole removal.
package enum CacheCleaner {
    package struct Root: Sendable {
        package let name: String
        package let url: URL

        package init(name: String, url: URL) {
            self.name = name
            self.url = url
        }
    }

    /// Derived data for large apps holds hundreds of thousands of files.
    static let maximumEntries = 4_194_304

    package static func clean(
        _ roots: [Root], dryRun: Bool, until deadline: ContinuousClock.Instant,
        beforeRemoval: () throws -> Void = {}
    ) throws -> CacheCleanResult {
        var locks: [FileLock] = []
        var found: [(Root, String)] = []
        for root in roots {
            var info = stat()
            guard lstat(root.url.path, &info) == 0 else {
                try requireRuntime(errno == ENOENT, "files", "Cannot inspect cache directory.")
                continue
            }
            let directory = try PrivateDirectory(root.url)
            locks.append(try FileLock(directory: directory, name: "build.lock"))
            for name in try directory.entries(limit: 256) where name != "build.lock" {
                found.append((root, name))
            }
        }
        // Checked after the locks are held, so no new helper build can start in between.
        try beforeRemoval()
        var removed: [CacheEntryRemoval] = []
        var freed: UInt64 = 0
        for (root, name) in found {
            let url = root.url.appendingPathComponent(name)
            let bytes = try RuntimeFiles.cacheBytes(
                url, maximumBytes: .max, maximumEntries: maximumEntries, until: deadline)
            if !dryRun { try RuntimeFiles.removeTree(url, until: deadline) }
            removed.append(CacheEntryRemoval(cache: root.name, key: name, bytes: bytes))
            freed += bytes
        }
        withExtendedLifetime(locks) {}
        return CacheCleanResult(dryRun: dryRun, entries: removed, freedBytes: freed)
    }
}
