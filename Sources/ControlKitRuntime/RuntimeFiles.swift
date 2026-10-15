import Darwin
import Foundation

enum RuntimeFiles {
    static func read(_ url: URL, limit: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw RuntimeFailure("files", "Cannot open bounded input.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        try requireRuntime(
            fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
                && info.st_size <= limit,
            "files", "Invalid or oversized input file.")
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        try requireRuntime(data.count <= limit, "resource_limit", "Input grew beyond its bound.")
        return data
    }

    static func entries(_ directory: URL, limit: Int) throws -> [String] {
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
            let stream = opendir(directory.path)
        else { throw RuntimeFailure("files", "Cannot list directory without following a symlink.") }
        defer { closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                try requireRuntime(errno == 0, "files", "Directory read failed.")
                return names.sorted()
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) {
                String(bytes: $0.prefix(Int(entry.pointee.d_namlen)), encoding: .utf8)
            }
            guard let name else { throw RuntimeFailure("files", "Invalid filename.") }
            if name == "." || name == ".." { continue }
            try requireRuntime(
                names.count < limit, "resource_limit", "Directory entry limit exceeded.")
            names.append(name)
        }
    }

    static func cacheBytes(
        _ root: URL, maximumBytes: UInt64 = 4 * 1_024 * 1_024 * 1_024,
        maximumEntries: Int = 16_384, until suppliedDeadline: ContinuousClock.Instant? = nil
    ) throws -> UInt64 {
        precondition(maximumEntries > 0)
        let deadline = suppliedDeadline ?? ContinuousClock.now.advanced(by: .seconds(5))
        var pending: [(URL, Int)] = [(root, 0)]
        var cursor = 0
        var entries = 0
        var bytes: UInt64 = 0
        while cursor < pending.count {
            let (directory, depth) = pending[cursor]
            cursor += 1
            for name in try self.entries(directory, limit: maximumEntries - entries) {
                try requireRuntime(
                    ContinuousClock.now < deadline, "deadline_exceeded", "Cache scan expired.")
                entries += 1
                let child = directory.appendingPathComponent(name)
                var info = stat()
                try requireRuntime(lstat(child.path, &info) == 0, "files", "Cannot inspect cache.")
                if info.st_mode & S_IFMT == S_IFDIR {
                    try requireRuntime(depth < 32, "resource_limit", "Cache depth exceeds 32.")
                    pending.append((child, depth + 1))
                } else if info.st_mode & S_IFMT == S_IFREG {
                    // Allocated blocks, not st_size: Xcode's compilation cache creates sparse
                    // files whose apparent size (tens of GiB) far exceeds their disk use.
                    bytes += UInt64(max(0, info.st_blocks)) * 512
                    try requireRuntime(
                        bytes <= maximumBytes,
                        "resource_limit", "Retained files exceed their byte budget.")
                }
            }
        }
        return bytes
    }
}
