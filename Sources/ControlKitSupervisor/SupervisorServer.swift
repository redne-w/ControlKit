import ControlKitRuntime
import ControlKitWire
import Foundation

package final class SupervisorServer: @unchecked Sendable {
    private let listener: LocalListener
    private let core: SupervisorCore
    private let clients = NSLock()
    private var clientCount = 0
    private var lastActivity = ContinuousClock.now
    private var lastExpiryCheck = ContinuousClock.now
    private var stopRequested = false

    package init(source: URL, cache: URL) throws {
        listener = try LocalListener()
        core = try SupervisorCore(source: source, cache: cache, tools: AppleTools())
    }

    package func run() throws {
        while true {
            if let socket = try listener.accept() {
                clients.lock()
                if clientCount >= 32 {
                    clients.unlock()
                    socket.close()
                } else {
                    clientCount += 1
                    lastActivity = .now
                    clients.unlock()
                    DispatchQueue.global().async { [self] in handle(socket) }
                }
            }
            clients.lock()
            let empty = clientCount == 0
            let idle = lastActivity.duration(to: .now) >= .seconds(120)
            let stopped = stopRequested
            clients.unlock()
            if lastExpiryCheck.duration(to: .now) >= .seconds(1) {
                lastExpiryCheck = .now
                DispatchQueue.global().async { [core] in core.expireSessions() }
            }
            if empty && (idle || stopped) && !core.hasLiveSessions { return }
        }
    }

    private func handle(_ socket: WireSocket) {
        defer {
            socket.close()
            clients.lock()
            clientCount -= 1
            lastActivity = .now
            clients.unlock()
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        do {
            let request = try socket.receiveJSON(
                SupervisorRequest.self, limit: 65_536, until: deadline)
            let response = core.handle(request)
            let responseDeadline = ContinuousClock.now.advanced(by: .seconds(5))
            try socket.sendJSON(
                response, limit: 2 * 1_024 * 1_024, until: responseDeadline)
            if request.operation == "supervisor.shutdown", response.ok {
                // Keep the accepted socket alive until the client can consume the terminal frame.
                Thread.sleep(forTimeInterval: 0.05)
                clients.lock()
                stopRequested = true
                clients.unlock()
            }
        } catch {
            return
        }
    }
}
