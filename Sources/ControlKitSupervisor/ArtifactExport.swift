import ControlKitRuntime
import Darwin
import Foundation

enum ArtifactExport {
    static func validate(_ path: String) throws {
        guard !path.isEmpty, path.utf8.count <= 4_096 else {
            throw RuntimeFailure("artifact_failed", "Invalid artifact path.")
        }
        let destination = URL(fileURLWithPath: path).standardizedFileURL
        let parent = try canonicalParent(destination)
        let final = parent.appendingPathComponent(destination.lastPathComponent)
        var info = stat()
        try requireRuntime(
            lstat(parent.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR,
            "artifact_failed", "Screenshot parent directory is unavailable.")
        guard lstat(final.path, &info) != 0, errno == ENOENT else {
            throw RuntimeFailure("file_exists", "Screenshot output already exists.")
        }
    }

    static func write(_ data: Data, to path: String) throws {
        guard data.count <= 32 * 1_024 * 1_024, !path.isEmpty, path.utf8.count <= 4_096 else {
            throw RuntimeFailure("artifact_failed", "Invalid artifact path or size.")
        }
        try validate(path)
        let destination = URL(fileURLWithPath: path).standardizedFileURL
        let parent = try canonicalParent(destination)
        let final = parent.appendingPathComponent(destination.lastPathComponent)
        var info = stat()
        guard lstat(final.path, &info) != 0, errno == ENOENT else {
            throw RuntimeFailure("file_exists", "Screenshot output already exists.")
        }
        let temporary = parent.appendingPathComponent(".controlkit-\(UUID().uuidString).tmp")
        let descriptor = open(
            temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw RuntimeFailure("artifact_failed", "Cannot create output.")
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
            guard count > 0 else { throw RuntimeFailure("artifact_failed", "Cannot write output.") }
            offset += count
        }
        guard fsync(descriptor) == 0,
            renameatx_np(AT_FDCWD, temporary.path, AT_FDCWD, final.path, UInt32(RENAME_EXCL)) == 0
        else { throw RuntimeFailure("artifact_failed", "Cannot publish completed output.") }
        published = true
    }

    static func canonicalParent(_ destination: URL) throws -> URL {
        let unresolved = destination.deletingLastPathComponent().path
        guard let resolved = realpath(unresolved, nil) else {
            throw RuntimeFailure("artifact_failed", "Cannot resolve screenshot parent directory.")
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }
}
