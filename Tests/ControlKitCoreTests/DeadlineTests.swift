import ControlKitCore
import ControlKitTestSupport
import Testing

struct DeadlineTests {
    @Test func exactBoundaryAndQueueTime() throws {
        var clock = ManualClock(milliseconds: 500)
        let deadline = try Deadline(now: clock.now, timeoutMilliseconds: 30_000)
        try clock.advance(milliseconds: 29_999)
        #expect(deadline.remainingMilliseconds(at: clock.now) == 1)
        #expect(!deadline.isExpired(at: clock.now))
        try clock.advance(milliseconds: 1)
        #expect(deadline.isExpired(at: clock.now))
        #expect(deadline.remainingMilliseconds(at: clock.now) == 0)
        try clock.advance(milliseconds: 1)
        #expect(deadline.remainingMilliseconds(at: clock.now) == 0)
    }

    @Test func invalidAndOverflowingBudgets() throws {
        let origin = MonotonicInstant(milliseconds: 0)
        #expect(throws: TimeFailure.invalidTimeout) {
            try Deadline(now: origin, timeoutMilliseconds: 0)
        }
        let last = MonotonicInstant(milliseconds: UInt64.max)
        #expect(throws: TimeFailure.overflow) {
            try Deadline(now: last, timeoutMilliseconds: 1)
        }
        let largest = try Deadline(now: origin, timeoutMilliseconds: UInt64.max)
        #expect(largest.remainingMilliseconds(at: origin) == UInt64.max)
        #expect(largest.isExpired(at: last))
    }

    @Test func laterAdmissionDoesNotExtendExistingDeadline() throws {
        var clock = ManualClock()
        let first = try Deadline(now: clock.now, timeoutMilliseconds: 1_000)
        try clock.advance(milliseconds: 500)
        let second = try Deadline(now: clock.now, timeoutMilliseconds: 1_000)
        try clock.advance(milliseconds: 500)
        #expect(first.isExpired(at: clock.now))
        #expect(second.remainingMilliseconds(at: clock.now) == 500)
    }

    @Test func generationNeverWrapsOrAcceptsZero() throws {
        #expect(throws: GenerationFailure.invalid) { try HelperGeneration(0) }
        let first = try HelperGeneration(1)
        #expect(try first.successor().value == 2)
        let last = try HelperGeneration(UInt64.max)
        #expect(throws: GenerationFailure.exhausted) { try last.successor() }
    }
}
