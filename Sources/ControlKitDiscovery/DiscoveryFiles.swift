import Darwin
import Foundation

/// Reads repository metadata only. No process execution, global configuration, or file writes.
final class DiscoveryFiles {
    enum Kind { case directory, regular, symlink, other }

    let budget: DiscoveryBudget
    private var listings: [URL: [String]] = [:]

    init(budget: DiscoveryBudget) { self.budget = budget }

    func kind(_ url: URL) throws -> Kind? {
        try budget.check()
        var attributes = stat()
        if lstat(url.path, &attributes) != 0 {
            if errno == ENOENT { return nil }
            throw failure(url)
        }
        switch attributes.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFREG: return .regular
        case S_IFLNK: return .symlink
        default: return .other
        }
    }

    func entries(_ directory: URL) throws -> [String] {
        try budget.check()
        if let cached = listings[directory] { return cached }
        guard try kind(directory) == .directory, let stream = opendir(directory.path) else {
            throw failure(directory)
        }
        defer { closedir(stream) }
        var names: [String] = []
        while true {
            try budget.check()
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw failure(directory) }
                break
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) {
                String(bytes: $0.prefix(Int(entry.pointee.d_namlen)), encoding: .utf8)
            }
            guard let name else { throw failure(directory) }
            if name == "." || name == ".." { continue }
            try budget.admitEntry()
            names.append(name)
        }
        names.sort()
        listings[directory] = names
        return names
    }

    func read(_ url: URL) throws -> Data {
        try budget.check()
        guard try kind(url) == .regular else { throw failure(url) }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure(url) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG else {
            throw failure(url)
        }
        guard attributes.st_size <= DiscoveryLimits.fileBytes else {
            throw DiscoveryFailure(.resourceLimit, "\(url.lastPathComponent) exceeds 64 KiB.")
        }
        var data = Data()
        while data.count <= DiscoveryLimits.fileBytes {
            try budget.check()
            let capacity = min(16_384, DiscoveryLimits.fileBytes + 1 - data.count)
            let chunk: Data
            do { chunk = try handle.read(upToCount: capacity) ?? Data() } catch {
                throw failure(url)
            }
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard data.count <= DiscoveryLimits.fileBytes else {
            throw DiscoveryFailure(.resourceLimit, "\(url.lastPathComponent) exceeds 64 KiB.")
        }
        return data
    }

    func failure(_ url: URL) -> DiscoveryFailure {
        DiscoveryFailure(.filesystemError, "Cannot read repository metadata at \(url.path).")
    }
}
