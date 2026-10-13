import ControlKitCore

/// Value-owned by each test; no globals, wall time, asynchronous sleeps, or shared scheduler.
package struct ManualClock {
    package private(set) var now: MonotonicInstant

    package init(milliseconds: UInt64 = 0) {
        now = MonotonicInstant(milliseconds: milliseconds)
    }

    package mutating func advance(milliseconds: UInt64) throws {
        // A failed advance leaves the clock untouched.
        now = try now.advanced(byMilliseconds: milliseconds)
    }
}
