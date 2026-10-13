/// Local monotonic milliseconds in one owner's clock domain; never a wall time or wire timestamp.
/// A clock adapter must use a fixed origin and floor elapsed time before constructing this value.
package struct MonotonicInstant: Comparable, Sendable {
    package let milliseconds: UInt64

    package init(milliseconds: UInt64) {
        self.milliseconds = milliseconds
    }

    package static func < (left: Self, right: Self) -> Bool {
        left.milliseconds < right.milliseconds
    }

    package func advanced(byMilliseconds delta: UInt64) throws -> Self {
        let (value, overflow) = milliseconds.addingReportingOverflow(delta)
        guard !overflow else { throw TimeFailure.overflow }
        return Self(milliseconds: value)
    }
}

package enum TimeFailure: Error, Equatable {
    case invalidTimeout
    case overflow
}

/// An immutable deadline: queueing or retrying must not refresh an operation's original budget.
/// Expiry is a fact about time, not proof that a dispatched action was cancelled.
package struct Deadline: Equatable, Sendable {
    package let expiresAt: MonotonicInstant

    package init(now: MonotonicInstant, timeoutMilliseconds: UInt64) throws {
        guard timeoutMilliseconds > 0 else { throw TimeFailure.invalidTimeout }
        expiresAt = try now.advanced(byMilliseconds: timeoutMilliseconds)
    }

    package func remainingMilliseconds(at now: MonotonicInstant) -> UInt64 {
        guard now < expiresAt else { return 0 }
        return expiresAt.milliseconds - now.milliseconds
    }

    package func isExpired(at now: MonotonicInstant) -> Bool {
        now >= expiresAt
    }
}
