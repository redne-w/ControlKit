import ControlKitCore
import ControlKitTestSupport
import Testing

struct SupportTests {
    @Test func knownSeedVector() {
        var generator = SeededGenerator(seed: 0)
        let values = (0..<3).map { _ in generator.next() }
        #expect(values == [0xe220_a839_7b1d_cdaf, 0x6e78_9e6a_a1b9_65f4, 0x06c4_5d18_8009_454f])
    }

    @Test func copiesReplayIndependently() {
        var original = SeededGenerator(seed: UInt64.max)
        var copy = original
        for _ in 0..<1_000 {
            #expect(original.next() == copy.next())
        }
        for _ in 0..<1_000 {
            let index = original.index(upperBound: 7)
            #expect((0..<7).contains(index))
        }
    }

    @Test func clockIsValueOwnedAndFailedAdvanceIsAtomic() throws {
        var clock = ManualClock(milliseconds: UInt64.max - 1)
        let copy = clock
        try clock.advance(milliseconds: 1)
        #expect(copy.now.milliseconds == UInt64.max - 1)
        #expect(throws: TimeFailure.overflow) { try clock.advance(milliseconds: 1) }
        #expect(clock.now.milliseconds == UInt64.max)
    }

    @Test func traceRetainsOnlyBoundedSuffix() {
        var trace = ReplayTrace(seed: 42)
        for index in 0..<100 { trace.record("event-\(index)") }
        #expect(trace.report.hasPrefix("Replay: just test-seeded 42\n68: event-68\n"))
        #expect(trace.report.hasSuffix("99: event-99"))
        for _ in 0..<100 { trace.record(String(repeating: "👋", count: 1_000)) }
        #expect(trace.report.utf8.count < 9_000)
    }
}
