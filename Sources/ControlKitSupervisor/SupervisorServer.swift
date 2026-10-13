import ControlKitRuntime
import ControlKitWire
import Darwin
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
        do {
            core = try SupervisorCore(source: source, cache: cache, tools: AppleTools())
        } catch {
            DiagnosticLog.failure("supervisor.start_failed", error)
            throw error
        }
        Self.boundErrorFile()
        DiagnosticLog.record(
            "supervisor.started",
            [
                "epoch": core.epoch.uuidString,
                "developerDirectory": core.tools.identity.developerDirectory,
                "xcode": "\(core.tools.identity.xcodeVersion) (\(core.tools.identity.xcodeBuild))",
            ])
    }

    /// Standard error is the append-only supervisor-stderr.log, which keeps Swift runtime trap
    /// messages. Only a fresh supervisor truncates it, which bounds it across restarts.
    private static func boundErrorFile() {
        var info = stat()
        guard fstat(STDERR_FILENO, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_size > 1_024 * 1_024
        else { return }
        _ = ftruncate(STDERR_FILENO, 0)
    }

    package func run() throws {
        while true {
            if let socket = try listener.accept() {
                clients.lock()
                if clientCount >= 32 {
                    clients.unlock()
                    socket.close()
                    DiagnosticLog.record("supervisor.client_rejected", ["limit": "32"])
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
            if empty && (idle || stopped) && !core.hasLiveSessions {
                DiagnosticLog.record(
                    "supervisor.stopped", ["reason": stopped ? "shutdown_request" : "idle"])
                return
            }
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
            // A client that exits or times out mid-frame is not a supervisor fault, but it is the
            // only trace of a lost reply, so record it.
            DiagnosticLog.failure("supervisor.client_failed", error)
        }
    }
}
