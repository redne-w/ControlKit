import Foundation

package struct OperationBudget {
    package let end: ContinuousClock.Instant

    package init(milliseconds: UInt64) {
        precondition(milliseconds > 0 && milliseconds <= 1_800_000)
        end = ContinuousClock.now.advanced(by: .milliseconds(Int64(milliseconds)))
    }

    package func remaining(maximum: UInt64) throws -> UInt64 {
        let now = ContinuousClock.now
        try requireRuntime(
            now < end, "deadline_exceeded", "Operation deadline exceeded before dispatch.")
        let duration = now.duration(to: end).components
        let milliseconds =
            UInt64(duration.seconds) * 1_000
            + UInt64(duration.attoseconds) / 1_000_000_000_000_000
        return min(maximum, max(1, milliseconds))
    }
}
