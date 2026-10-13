import ControlKitCore

enum DiscoveryLimits {
    static let ancestors = 32
    static let entries = 1_024
    static let depth = 4
    static let fileBytes = 65_536
    static let jsonDepth = 32
    static let profiles = 16
    static let fieldBytes = 4_096
}

/// Owned by one synchronous discovery operation. It never suspends or extends its deadline.
final class DiscoveryBudget {
    private let now: () -> MonotonicInstant
    private let deadline: Deadline
    private(set) var entryCount = 0

    init(timeoutMilliseconds: UInt64, now: @escaping () -> MonotonicInstant) throws {
        guard (1...30_000).contains(timeoutMilliseconds) else {
            throw DiscoveryFailure(.invalidConfiguration, "Discovery timeout must be 1–30000 ms.")
        }
        self.now = now
        deadline = try Deadline(now: now(), timeoutMilliseconds: timeoutMilliseconds)
    }

    func check() throws {
        guard !deadline.isExpired(at: now()) else {
            throw DiscoveryFailure(.deadlineExceeded, "Repository discovery deadline exceeded.")
        }
    }

    func admitEntry() throws {
        try check()
        guard entryCount < DiscoveryLimits.entries else {
            throw DiscoveryFailure(
                .resourceLimit,
                "Discovery exceeded 1024 entries; narrow --project or select a container.")
        }
        entryCount += 1
    }

    static func systemTime() -> () -> MonotonicInstant {
        let origin = ContinuousClock.now
        return {
            let duration = origin.duration(to: .now).components
            precondition(duration.seconds >= 0 && duration.attoseconds >= 0)
            let milliseconds =
                UInt64(duration.seconds) * 1_000
                + UInt64(duration.attoseconds) / 1_000_000_000_000_000
            return MonotonicInstant(milliseconds: milliseconds)
        }
    }
}
