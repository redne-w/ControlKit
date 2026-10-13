import Darwin
import Foundation

/// Signal sources coalesce delivery. Only the cancellation bit crosses threads; transitions do not.
package final class CancellationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    private var sources: [any DispatchSourceSignal] = []
    private let previousINT: sig_t?
    private let previousTERM: sig_t?

    package init() {
        previousINT = signal(SIGINT, SIG_IGN)
        previousTERM = signal(SIGTERM, SIG_IGN)
        for number in [SIGINT, SIGTERM] {
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { [weak self] in self?.request() }
            sources.append(source)
            source.resume()
        }
    }

    deinit {
        for source in sources { source.cancel() }
        signal(SIGINT, previousINT)
        signal(SIGTERM, previousTERM)
    }

    package var isRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    private func request() {
        lock.lock()
        requested = true
        lock.unlock()
    }
}
