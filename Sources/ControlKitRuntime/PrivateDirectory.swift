import Darwin
import Foundation

/// Descriptor-relative operations avoid following a replaced leaf or credential-file symlink.
package final class PrivateDirectory {
    package let url: URL
    let descriptor: Int32

    package init(_ url: URL) throws {
        self.url = url
        if mkdir(url.path, 0o700) != 0, errno != EEXIST {
            throw RuntimeFailure("private_files", "Cannot create private directory.")
        }
        descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw RuntimeFailure("private_files", "Invalid directory.") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(),
            info.st_mode & 0o777 == 0o700
        else {
            close(descriptor)
            throw RuntimeFailure("private_files", "Directory must be owned by you with mode 0700.")
        }
    }

    deinit { close(descriptor) }

    func openFile(_ name: String, flags: Int32) throws -> Int32 {
        try validateName(name)
        let file = openat(descriptor, name, flags | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard file >= 0 else { throw RuntimeFailure("private_files", "Cannot open private file.") }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
            info.st_mode & 0o777 == 0o600, info.st_nlink == 1
        else {
            close(file)
            throw RuntimeFailure("private_files", "Invalid private file owner, mode, or type.")
        }
        return file
    }

    package func write(_ name: String, data: Data) throws {
        try requireRuntime(data.count <= 65_536, "resource_limit", "Private file exceeds 64 KiB.")
        let file = try openFile(name, flags: O_WRONLY | O_CREAT | O_EXCL)
        defer { close(file) }
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes {
                Darwin.write(file, $0.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw RuntimeFailure("private_files", "Cannot write private file.")
            }
            offset += count
        }
    }

    package func exists(_ name: String) throws -> Bool {
        try validateName(name)
        var info = stat()
        if fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        guard errno == ENOENT else { throw RuntimeFailure("private_files", "Cannot inspect file.") }
        return false
    }

    package func remove(_ name: String) throws {
        try validateName(name)
        guard unlinkat(descriptor, name, 0) == 0 else {
            throw RuntimeFailure("private_files", "Cannot retire private file.")
        }
    }

    package func entries(limit: Int = 256) throws -> [String] {
        let copy = dup(descriptor)
        guard copy >= 0 else { throw RuntimeFailure("private_files", "Cannot list directory.") }
        guard let stream = fdopendir(copy) else {
            close(copy)
            throw RuntimeFailure("private_files", "Cannot list directory.")
        }
        defer { closedir(stream) }
        rewinddir(stream)
        var result: [String] = []
        while true {
            errno = 0
            guard let item = readdir(stream) else {
                guard errno == 0 else {
                    throw RuntimeFailure("private_files", "Directory read failed.")
                }
                return result.sorted()
            }
            let name = withUnsafeBytes(of: item.pointee.d_name) {
                String(bytes: $0.prefix(Int(item.pointee.d_namlen)), encoding: .utf8)
            }
            guard let name else { throw RuntimeFailure("private_files", "Invalid filename.") }
            if name == "." || name == ".." { continue }
            try requireRuntime(result.count < limit, "resource_limit", "Private directory is full.")
            result.append(name)
        }
    }

    private func validateName(_ name: String) throws {
        try requireRuntime(
            !name.isEmpty && name.utf8.count <= 128 && name != "." && name != ".."
                && !name.contains("/") && !name.utf8.contains(0),
            "private_files", "Invalid private filename.")
    }
}

package final class FileLock {
    let descriptor: Int32

    package init(directory: PrivateDirectory, name: String) throws {
        descriptor = try directory.openFile(name, flags: O_RDWR | O_CREAT)
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw RuntimeFailure("device_busy", "Another operation owns this resource.")
        }
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
