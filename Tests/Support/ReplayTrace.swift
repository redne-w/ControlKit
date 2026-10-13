/// Keep only a bounded suffix; failure messages always include the seed and absolute step number.
package struct ReplayTrace {
    package let seed: UInt64
    private var step = 0
    private var events: [String] = []

    package init(seed: UInt64) { self.seed = seed }

    package mutating func record(_ event: String) {
        if events.count == 32 { events.removeFirst() }
        let bounded = String(decoding: event.utf8.prefix(256), as: UTF8.self)
        events.append("\(step): \(bounded)")
        step += 1
    }

    package var report: String {
        "Replay: just test-seeded \(seed)\n" + events.joined(separator: "\n")
    }
}
