import Darwin
import Foundation

package enum SessionRetention {
    static let maximumRuns = 32
    static let maximumBytes: UInt64 = 256 * 1_024 * 1_024
    static let marker = "retired-v1"
    private static let lockName = "retention.lock"

    package static func reserve(
        _ id: UUID, in root: PrivateDirectory,
        until deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(5))
    ) throws -> PrivateDirectory {
        let lock = try acquireLock(root, until: deadline)
        _ = lock
        var runs = try inspect(root, until: deadline)
        while runs.count >= maximumRuns || totalBytes(runs) > maximumBytes {
            guard let victim = runs.filter(\.retired).min(by: older) else {
                throw RuntimeFailure(
                    "resource_limit", "Private runtime retention has no evictable runs.")
            }
            try remove(victim.url, until: deadline)
            runs.removeAll { $0.name == victim.name }
        }
        return try PrivateDirectory(root.url.appendingPathComponent(id.uuidString))
    }

    package static func markRetired(_ run: PrivateDirectory) throws {
        var info = stat()
        if lstat(run.url.path, &info) != 0 {
            try requireRuntime(
                errno == ENOENT, "private_files", "Cannot inspect retired runtime.")
            return
        }
        if try retiredMarker(run.url) != nil { return }
        try run.write(marker, data: Data())
    }

    private static func acquireLock(
        _ root: PrivateDirectory, until deadline: ContinuousClock.Instant
    ) throws -> FileLock {
        while true {
            do { return try FileLock(directory: root, name: lockName) } catch let failure
                as RuntimeFailure
            {
                guard failure.code == "device_busy", ContinuousClock.now < deadline else {
                    throw failure
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
    }

    private struct Run {
        let name: String
        let url: URL
        let bytes: UInt64
        let retired: Bool
        let retirementTime: timespec
    }

    private static func inspect(
        _ root: PrivateDirectory, until deadline: ContinuousClock.Instant
    ) throws -> [Run] {
        let names = try root.entries(limit: 256)
        var runs: [Run] = []
        for name in names where name != lockName {
            try requireRuntime(
                UUID(uuidString: name) != nil, "private_files",
                "Unexpected session runtime entry.")
            let url = root.url.appendingPathComponent(name)
            var info = stat()
            try requireRuntime(
                lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR,
                "private_files", "Session runtime entry is not a directory.")
            let bytes = try RuntimeFiles.cacheBytes(
                url, maximumBytes: UInt64.max, maximumEntries: 16_384, until: deadline)
            let markerInfo = try retiredMarker(url)
            runs.append(
                Run(
                    name: name, url: url, bytes: bytes, retired: markerInfo != nil,
                    retirementTime: markerInfo?.st_mtimespec ?? timespec()))
        }
        return runs
    }

    private static func retiredMarker(_ run: URL) throws -> stat? {
        let url = run.appendingPathComponent(marker)
        var info = stat()
        if lstat(url.path, &info) != 0 {
            try requireRuntime(
                errno == ENOENT, "private_files", "Cannot inspect retirement marker.")
            return nil
        }
        try requireRuntime(
            info.st_mode & S_IFMT == S_IFREG && info.st_uid == getuid()
                && info.st_mode & 0o777 == 0o600 && info.st_nlink == 1
                && info.st_size == 0,
            "private_files", "Invalid retirement marker.")
        return info
    }

    private static func older(_ lhs: Run, _ rhs: Run) -> Bool {
        if lhs.retirementTime.tv_sec != rhs.retirementTime.tv_sec {
            return lhs.retirementTime.tv_sec < rhs.retirementTime.tv_sec
        }
        if lhs.retirementTime.tv_nsec != rhs.retirementTime.tv_nsec {
            return lhs.retirementTime.tv_nsec < rhs.retirementTime.tv_nsec
        }
        return lhs.name < rhs.name
    }

    private static func totalBytes(_ runs: [Run]) -> UInt64 {
        runs.reduce(0) { partial, run in
            let (sum, overflow) = partial.addingReportingOverflow(run.bytes)
            return overflow ? UInt64.max : sum
        }
    }

    private static func remove(
        _ root: URL, until deadline: ContinuousClock.Instant
    ) throws {
        var pending: [(URL, Int, Bool)] = [(root, 0, false)]
        var entries = 0
        while let (url, depth, visited) = pending.popLast() {
            try requireRuntime(
                ContinuousClock.now < deadline, "deadline_exceeded",
                "Session eviction expired.")
            if visited {
                if depth == 0 {
                    try requireRuntime(
                        unlink(url.appendingPathComponent(marker).path) == 0,
                        "private_files", "Cannot remove retirement marker.")
                }
                try requireRuntime(
                    rmdir(url.path) == 0, "private_files", "Cannot remove retired run.")
                continue
            }
            pending.append((url, depth, true))
            for name in try RuntimeFiles.entries(url, limit: 16_384 - entries) {
                try requireRuntime(
                    ContinuousClock.now < deadline, "deadline_exceeded",
                    "Session eviction expired.")
                if depth == 0, name == marker { continue }
                entries += 1
                let child = url.appendingPathComponent(name)
                var info = stat()
                try requireRuntime(
                    lstat(child.path, &info) == 0, "private_files",
                    "Cannot inspect retired run.")
                if info.st_mode & S_IFMT == S_IFDIR {
                    try requireRuntime(
                        depth < 32, "resource_limit", "Session runtime depth exceeds 32.")
                    pending.append((child, depth + 1, false))
                } else {
                    try requireRuntime(
                        unlink(child.path) == 0, "private_files",
                        "Cannot remove retired run entry.")
                }
            }
        }
    }
}
