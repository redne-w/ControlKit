import ControlKitRuntime
import Darwin
import Foundation

enum ConfigurationWriter {
    static func write(_ data: Data, to url: URL, replace: Bool) throws {
        try requireRuntime(
            data.count <= 65_536, "resource_limit", "Configuration exceeds 64 KiB.")
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
        var info = stat()
        try requireRuntime(
            lstat(parent.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR,
            "configuration_invalid", "Configuration parent is unavailable.")
        if lstat(url.path, &info) == 0 {
            try requireRuntime(
                replace && info.st_mode & S_IFMT == S_IFREG,
                "file_exists", "controlkit.json already exists; use explicit replacement.")
        } else {
            try requireRuntime(
                errno == ENOENT, "configuration_invalid", "Cannot inspect controlkit.json.")
        }
        let temporary = parent.appendingPathComponent(".controlkit-\(UUID().uuidString).tmp")
        let descriptor = open(
            temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            throw RuntimeFailure("configuration_invalid", "Cannot create configuration.")
        }
        var published = false
        defer {
            close(descriptor)
            if !published { unlink(temporary.path) }
        }
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes {
                Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if count < 0, errno == EINTR { continue }
            try requireRuntime(count > 0, "configuration_invalid", "Cannot write configuration.")
            offset += count
        }
        try requireRuntime(fsync(descriptor) == 0, "configuration_invalid", "Cannot sync config.")
        let flags = replace ? UInt32(RENAME_SWAP) : UInt32(RENAME_EXCL)
        if replace {
            try requireRuntime(
                renameatx_np(AT_FDCWD, temporary.path, AT_FDCWD, url.path, flags) == 0,
                "configuration_invalid", "Cannot replace controlkit.json atomically.")
            try requireRuntime(
                unlink(temporary.path) == 0, "configuration_invalid",
                "Cannot retire the previous configuration.")
        } else {
            try requireRuntime(
                renameatx_np(AT_FDCWD, temporary.path, AT_FDCWD, url.path, flags) == 0,
                "configuration_invalid", "Cannot publish controlkit.json.")
        }
        published = true
    }
}
