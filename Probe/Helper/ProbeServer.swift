import Foundation
import Network

/// The lock bridges Network's serial queue to XCTest's main actor. Capacity is exactly one.
final class ProbeMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: ProbeRequest?
    private var failure: String?
    private var stopped = false

    func submit(_ request: ProbeRequest) {
        lock.lock()
        defer { lock.unlock() }
        precondition(pending == nil)
        precondition(!stopped)
        pending = request
    }

    func take() -> (ProbeRequest?, String?, Bool) {
        lock.lock()
        defer { lock.unlock() }
        let value = pending
        pending = nil
        return (value, failure, stopped)
    }

    func finish(failure: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        self.failure = failure
        stopped = true
    }
}

/// Except for the mailbox, mutable state is confined to `queue`.
final class ProbeServer: @unchecked Sendable {
    let mailbox = ProbeMailbox()
    private let queue = DispatchQueue(label: "ControlKit.probe.server")
    private let listener: NWListener
    private let token: String
    private var active: NWConnection?
    private var timer: DispatchWorkItem?

    init(port: UInt16, token: String) throws {
        precondition(port > 0)
        precondition((32...128).contains(token.utf8.count))
        self.token = token
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!
        )
        listener = try NWListener(using: parameters)
    }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state {
                print("CONTROLKIT_PROBE_READY")
            }
            if case .failed = state {
                mailbox.finish(failure: "Loopback listener failed.")
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            active?.cancel()
            listener.cancel()
        }
    }

    func reply(_ response: ProbeResponse, stop: Bool) {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            guard let connection = active else {
                mailbox.finish(failure: "Lost the active command connection.")
                return
            }
            do {
                let body = try JSONEncoder().encode(response)
                let frame = try ProbeWire.frame(body, limit: ProbeLimits.responseBytes)
                armDeadline(connection)
                connection.send(
                    content: frame,
                    completion: .contentProcessed { [self] error in
                        release(connection)
                        if error != nil {
                            mailbox.finish(
                                failure: "Reply delivery failed; action outcome is uncertain.")
                        } else if stop {
                            mailbox.finish()
                        }
                    })
            } catch {
                release(connection)
                mailbox.finish(failure: "Cannot encode a bounded command response.")
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard active == nil else {
            // Production scheduling is a later milestone. This probe never queues another client.
            connection.cancel()
            return
        }
        active = connection
        connection.start(queue: queue)
        armDeadline(connection)
        ProbeWire.receive(from: connection, limit: ProbeLimits.requestBytes) { [self] result in
            guard active === connection else { return }
            timer?.cancel()
            do {
                let request = try JSONDecoder().decode(ProbeRequest.self, from: result.get())
                guard request.token == token else {
                    release(connection)
                    return
                }
                do {
                    try request.validate()
                    mailbox.submit(request)
                } catch let failure as ProbeFailure {
                    var response = ProbeResponse(id: request.id)
                    response.ok = false
                    response.error = failure
                    reply(response, stop: false)
                }
            } catch {
                release(connection)
            }
        }
    }

    private func armDeadline(_ connection: NWConnection) {
        dispatchPrecondition(condition: .onQueue(queue))
        timer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.release(connection)
        }
        timer = item
        queue.asyncAfter(deadline: .now() + 10, execute: item)
    }

    private func release(_ connection: NWConnection) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard active === connection else { return }
        timer?.cancel()
        timer = nil
        connection.cancel()
        active = nil
    }
}
