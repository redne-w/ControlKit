import ControlKitCore
import ControlKitTestSupport
import Foundation
import Testing

@testable import ControlKitDiscovery

struct DiscoveryLimitTests {
    @Test func entryLimitIsExactAndCachedListingsAreNotRecharged() throws {
        let fixture = try DiscoveryFixture()
        for index in 0..<DiscoveryLimits.entries { try fixture.write("entry-\(index)", "") }
        let clock = ManualClock()
        let budget = try DiscoveryBudget(timeoutMilliseconds: 1_000, now: { clock.now })
        let files = DiscoveryFiles(budget: budget)
        #expect(try files.entries(fixture.root).count == DiscoveryLimits.entries)
        #expect(try files.entries(fixture.root).count == DiscoveryLimits.entries)
        #expect(budget.entryCount == DiscoveryLimits.entries)
        _ = try fixture.resolve()
        try fixture.write("one-too-many", "")
        expectFailure(.resourceLimit) { _ = try fixture.resolve() }
    }

    @Test func depthLimitDoesNotTurnIncompleteTraversalIntoUniqueness() throws {
        let fixture = try DiscoveryFixture()
        try fixture.project("a/b/c/AtLimit.xcodeproj")
        #expect(try fixture.resolve().candidates.count == 1)
        try fixture.project("a/b/c/d/TooDeep.xcodeproj")
        expectFailure(.resourceLimit) { _ = try fixture.resolve() }
        let explicit = try fixture.resolve { $0.xcodeProject = "a/b/c/d/TooDeep.xcodeproj" }
        #expect(explicit.container?.source.kind == .explicit)
    }

    @Test func ancestorLimitIsExact() throws {
        let fixture = try DiscoveryFixture()
        try fixture.directory(".git")
        let atLimit = try fixture.directory(Array(repeating: "d", count: 31).joined(separator: "/"))
        try fixture.project()
        var options = DiscoveryOptions()
        options.xcodeProject = "App.xcodeproj"
        let found = try RepositoryDiscovery.resolve(options: options, currentDirectory: atLimit)
        #expect(found.root == fixture.root.path)
        let beyond = try fixture.directory(Array(repeating: "d", count: 32).joined(separator: "/"))
        expectFailure(.resourceLimit) {
            _ = try RepositoryDiscovery.resolve(options: options, currentDirectory: beyond)
        }
    }

    @Test func fileSizeLimitIsExact() throws {
        let fixture = try DiscoveryFixture()
        try fixture.write("buildServer.json", "{}" + String(repeating: " ", count: 65_534))
        _ = try fixture.resolve()
        try fixture.write("buildServer.json", "{}" + String(repeating: " ", count: 65_535))
        expectFailure(.resourceLimit) { _ = try fixture.resolve() }
    }

    @Test func duplicateKeysIncludingEscapedSpellingsAreRejectedWithoutEchoingInput() throws {
        for text in [
            #"{"name":"secret-value","na\u006de":"other"}"#,
            #"{"unknown":{"key":1,"key":2}}"#,
            #"{"unknown":[{"key":1,"key":2}]}"#,
            #"{"name":"secret-value""#,
        ] {
            do {
                _ = try ConfigurationJSON.decode(BuildServerHeader.self, data: Data(text.utf8))
                Issue.record("Expected invalid JSON.")
            } catch let error as DiscoveryFailure {
                #expect(error.code == .invalidConfiguration)
                #expect(!error.message.contains("secret-value"))
            }
        }
    }

    @Test func nestingCapAndStringEscapes() throws {
        func json(depth: Int) -> Data {
            Data(
                ("{\"unknown\":" + String(repeating: "[", count: depth - 1)
                    + "0" + String(repeating: "]", count: depth - 1) + "}").utf8)
        }
        _ = try ConfigurationJSON.decode(BuildServerHeader.self, data: json(depth: 32))
        expectFailure(.resourceLimit) {
            _ = try ConfigurationJSON.decode(BuildServerHeader.self, data: json(depth: 33))
        }
        let escaped = #"{"name":"quotes\" brackets[{}] slash\\","unknown":[{},{}]}"#
        let header = try ConfigurationJSON.decode(BuildServerHeader.self, data: Data(escaped.utf8))
        #expect(header.name == "quotes\" brackets[{}] slash\\")
    }

    @Test func profileAndFieldLimits() throws {
        let fixture = try DiscoveryFixture()
        for count in [16, 17] {
            let profiles = Dictionary(
                uniqueKeysWithValues: (0..<count).map { ("p\($0)", [:] as [String: String]) })
            let data = try JSONSerialization.data(
                withJSONObject: ["schemaVersion": 1, "profiles": profiles])
            try data.write(to: fixture.root.appendingPathComponent("controlkit.json"))
            if count == 16 {
                _ = try fixture.resolve()
            } else {
                expectFailure(.resourceLimit) { _ = try fixture.resolve() }
            }
        }
        try validateSetting(String(repeating: "a", count: 4_096), field: "test")
        for value in ["", "\n", String(repeating: "a", count: 4_097)] {
            expectFailure(.invalidConfiguration) { try validateSetting(value, field: "test") }
        }
    }

    @Test func sharedDeadlineExpiresAtBoundaryWithoutSleeps() throws {
        var clock = ManualClock(milliseconds: 100)
        let budget = try DiscoveryBudget(timeoutMilliseconds: 5, now: { clock.now })
        try clock.advance(milliseconds: 4)
        try budget.check()
        try clock.advance(milliseconds: 1)
        expectFailure(.deadlineExceeded) { try budget.check() }
        for timeout: UInt64 in [0, 30_001] {
            expectFailure(.invalidConfiguration) {
                _ = try DiscoveryBudget(timeoutMilliseconds: timeout, now: { clock.now })
            }
        }
        let fixture = try DiscoveryFixture()
        var ticks: UInt64 = 0
        var options = DiscoveryOptions()
        options.projectDirectory = fixture.root.path
        options.timeoutMilliseconds = 3
        expectFailure(.deadlineExceeded) {
            _ = try RepositoryDiscovery.resolve(
                options: options, currentDirectory: fixture.root,
                now: {
                    ticks += 1
                    return MonotonicInstant(milliseconds: ticks)
                })
        }
    }
}
