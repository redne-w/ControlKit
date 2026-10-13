import Darwin
import Foundation
import Testing

@testable import ControlKitRuntime

struct SessionRetentionTests {
    @Test func countBoundaryEvictsRetiredAndPreservesActive() throws {
        let fixture = try RetentionFixture()
        defer { fixture.remove() }
        let retired = try fixture.run(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        try SessionRetention.markRetired(retired)
        for _ in 1..<SessionRetention.maximumRuns {
            _ = try fixture.run(UUID())
        }

        let reserved = try SessionRetention.reserve(UUID(), in: fixture.root)

        #expect(!FileManager.default.fileExists(atPath: retired.url.path))
        #expect(FileManager.default.fileExists(atPath: reserved.url.path))
        #expect(try fixture.runCount() == SessionRetention.maximumRuns)
    }

    @Test func countBoundaryFailsWhenEveryRunIsActive() throws {
        let fixture = try RetentionFixture()
        defer { fixture.remove() }
        for _ in 0..<SessionRetention.maximumRuns {
            _ = try fixture.run(UUID())
        }

        #expect(throws: RuntimeFailure.self) {
            _ = try SessionRetention.reserve(UUID(), in: fixture.root)
        }
        #expect(try fixture.runCount() == SessionRetention.maximumRuns)
    }

    @Test func deterministicRetirementOrderBreaksTimestampTiesByUUID() throws {
        let fixture = try RetentionFixture()
        defer { fixture.remove() }
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let first = try fixture.run(firstID)
        let second = try fixture.run(secondID)
        try SessionRetention.markRetired(first)
        try SessionRetention.markRetired(second)
        try fixture.setMarkerTime(first, seconds: 10)
        try fixture.setMarkerTime(second, seconds: 10)
        for _ in 2..<SessionRetention.maximumRuns {
            _ = try fixture.run(UUID())
        }

        _ = try SessionRetention.reserve(UUID(), in: fixture.root)

        #expect(!FileManager.default.fileExists(atPath: first.url.path))
        #expect(FileManager.default.fileExists(atPath: second.url.path))
    }

    @Test func byteBoundaryEvictsOnlyAfterBudgetIsExceeded() throws {
        let fixture = try RetentionFixture()
        defer { fixture.remove() }
        let run = try fixture.run(UUID())
        try SessionRetention.markRetired(run)
        try fixture.sparseFile(run, bytes: SessionRetention.maximumBytes)
        _ = try SessionRetention.reserve(UUID(), in: fixture.root)
        #expect(FileManager.default.fileExists(atPath: run.url.path))
        try fixture.resizeSparseFile(run, bytes: SessionRetention.maximumBytes + 1)
        _ = try SessionRetention.reserve(UUID(), in: fixture.root)

        #expect(!FileManager.default.fileExists(atPath: run.url.path))
    }

    @Test func malformedMarkerAndRootSymlinkFailClosed() throws {
        let fixture = try RetentionFixture()
        defer { fixture.remove() }
        let run = try fixture.run(UUID())
        try FileManager.default.createSymbolicLink(
            at: run.url.appendingPathComponent(SessionRetention.marker),
            withDestinationURL: run.url)
        #expect(throws: RuntimeFailure.self) {
            _ = try SessionRetention.reserve(UUID(), in: fixture.root)
        }
        let link = fixture.url.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: run.url)
        #expect(throws: RuntimeFailure.self) {
            _ = try SessionRetention.reserve(UUID(), in: fixture.root)
        }
    }

    @Test func evictionUnlinksSymlinksAndNonregularEntriesWithoutFollowing() throws {
        let fixture = try RetentionFixture()
        defer { fixture.remove() }
        let run = try fixture.run(UUID())
        try SessionRetention.markRetired(run)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("preserve".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: run.url.appendingPathComponent("link"), withDestinationURL: outside)
        try #require(mkfifo(run.url.appendingPathComponent("pipe").path, 0o600) == 0)
        for _ in 1..<SessionRetention.maximumRuns {
            _ = try fixture.run(UUID())
        }

        _ = try SessionRetention.reserve(UUID(), in: fixture.root)

        #expect(!FileManager.default.fileExists(atPath: run.url.path))
        #expect(try Data(contentsOf: outside) == Data("preserve".utf8))
    }

    @Test func retirementMarkerIsIdempotentAfterRetirementAndEviction() throws {
        let fixture = try RetentionFixture()
        defer { fixture.remove() }
        let retired = try fixture.run(UUID())
        try SessionRetention.markRetired(retired)
        try SessionRetention.markRetired(retired)
        for _ in 1..<SessionRetention.maximumRuns {
            _ = try fixture.run(UUID())
        }
        _ = try SessionRetention.reserve(UUID(), in: fixture.root)
        try SessionRetention.markRetired(retired)
    }
}

private final class RetentionFixture {
    let url: URL
    let root: PrivateDirectory

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = try PrivateDirectory(url)
    }

    func run(_ id: UUID) throws -> PrivateDirectory {
        try PrivateDirectory(url.appendingPathComponent(id.uuidString))
    }

    func runCount() throws -> Int {
        try root.entries().filter { UUID(uuidString: $0) != nil }.count
    }

    func sparseFile(_ run: PrivateDirectory, bytes: UInt64) throws {
        let path = run.url.appendingPathComponent("artifact").path
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        try #require(ftruncate(descriptor, off_t(bytes)) == 0)
    }

    func resizeSparseFile(_ run: PrivateDirectory, bytes: UInt64) throws {
        let path = run.url.appendingPathComponent("artifact").path
        let descriptor = open(path, O_WRONLY)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        try #require(ftruncate(descriptor, off_t(bytes)) == 0)
    }

    func setMarkerTime(_ run: PrivateDirectory, seconds: Int) throws {
        let path = run.url.appendingPathComponent(SessionRetention.marker).path
        var times = [timespec(tv_sec: seconds, tv_nsec: 0), timespec(tv_sec: seconds, tv_nsec: 0)]
        try times.withUnsafeMutableBufferPointer {
            try #require(utimensat(AT_FDCWD, path, $0.baseAddress, 0) == 0)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
