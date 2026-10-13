import Foundation
import Network

/// Mutable state is protected by the lock; completion is terminal and happens at most once.
private final class ProbeReply: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Data, ProbeFailure>?
    private var dispatched = false
    let ready = DispatchSemaphore(value: 0)

    func beginDispatch() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard result == nil, !dispatched else { return false }
        dispatched = true
        return true
    }

    func connectionFailure() -> ProbeFailure {
        lock.lock()
        defer { lock.unlock() }
        if dispatched {
            return ProbeFailure(
                "outcome_unknown", "Connection failed after dispatch; do not replay.")
        }
        return ProbeFailure(
            "transport_unavailable", "Cannot establish the local helper connection.")
    }

    func finish(_ value: Result<Data, ProbeFailure>) {
        lock.lock()
        defer { lock.unlock() }
        guard result == nil else { return }
        result = value
        ready.signal()
    }

    func get() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        precondition(result != nil)
        return try result!.get()
    }
}

public enum ProbeClient {
    public static func send(
        _ request: ProbeRequest, port: UInt16, timeoutSeconds: Double
    ) throws -> ProbeResponse {
        try request.validate()
        guard port > 0, timeoutSeconds.isFinite, (0.1...120).contains(timeoutSeconds) else {
            throw ProbeFailure("invalid_endpoint", "Port or timeout is outside the probe limits.")
        }
        let body = try JSONEncoder().encode(request)
        let frame = try ProbeWire.frame(body, limit: ProbeLimits.requestBytes)
        let reply = ProbeReply()
        let connection = NWConnection(
            host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp
        )
        defer { connection.cancel() }
        configure(connection, frame: frame, reply: reply)
        connection.start(queue: DispatchQueue(label: "ControlKit.probe.client"))
        guard reply.ready.wait(timeout: .now() + timeoutSeconds) == .success else {
            // The runner may still be executing. The probe deliberately does not retry.
            throw ProbeFailure("outcome_unknown", "Deadline expired; do not replay a mutation.")
        }
        let response = try JSONDecoder().decode(ProbeResponse.self, from: reply.get())
        guard response.version == 1, response.id == request.id else {
            throw ProbeFailure("invalid_response", "Response version or request ID does not match.")
        }
        guard response.ok == (response.error == nil) else {
            throw ProbeFailure("invalid_response", "Response success and error fields disagree.")
        }
        return response
    }

    private static func configure(_ connection: NWConnection, frame: Data, reply: ProbeReply) {
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                guard reply.beginDispatch() else { return }
                connection.send(
                    content: frame,
                    completion: .contentProcessed { error in
                        guard error == nil else {
                            reply.finish(
                                .failure(
                                    ProbeFailure(
                                        "outcome_unknown",
                                        "Connection failed while sending the request."
                                    )))
                            return
                        }
                        ProbeWire.receive(from: connection, limit: ProbeLimits.responseBytes) {
                            result in
                            reply.finish(
                                result.mapError { _ in
                                    ProbeFailure(
                                        "outcome_unknown", "Connection closed before a response.")
                                })
                        }
                    })
            case .failed, .waiting:
                reply.finish(.failure(reply.connectionFailure()))
            default:
                break
            }
        }
    }
}
