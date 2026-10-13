import Foundation
import Network

/// One bounded, length-prefixed JSON message per connection. No remote listener or HTTP stack.
public enum ProbeWire {
    public static func frame(_ body: Data, limit: Int) throws -> Data {
        guard !body.isEmpty, body.count <= limit, body.count <= Int(UInt32.max) else {
            throw ProbeFailure("invalid_frame", "Message length exceeds the frame limit.")
        }
        let count = UInt32(body.count)
        var result = Data([
            UInt8(truncatingIfNeeded: count >> 24), UInt8(truncatingIfNeeded: count >> 16),
            UInt8(truncatingIfNeeded: count >> 8), UInt8(truncatingIfNeeded: count),
        ])
        result.append(body)
        return result
    }

    public static func length(_ header: Data, limit: Int) throws -> Int {
        guard header.count == 4 else {
            throw ProbeFailure("invalid_frame", "Expected a four-byte frame header.")
        }
        let count = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard count > 0, count <= limit else {
            throw ProbeFailure("invalid_frame", "Message length exceeds the frame limit.")
        }
        return Int(count)
    }

    public static func receive(
        from connection: NWConnection, limit: Int,
        completion: @escaping @Sendable (Result<Data, ProbeFailure>) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, error in
            guard error == nil, let header else {
                completion(.failure(ProbeFailure("connection_closed", "No complete frame header.")))
                return
            }
            do {
                let count = try length(header, limit: limit)
                receiveBody(from: connection, count: count, completion: completion)
            } catch let failure as ProbeFailure {
                completion(.failure(failure))
            } catch {
                completion(.failure(ProbeFailure("invalid_frame", "Cannot decode frame length.")))
            }
        }
    }

    private static func receiveBody(
        from connection: NWConnection, count: Int,
        completion: @escaping @Sendable (Result<Data, ProbeFailure>) -> Void
    ) {
        precondition(count > 0)
        connection.receive(minimumIncompleteLength: count, maximumLength: count) {
            body, _, _, error in
            guard error == nil, let body, body.count == count else {
                completion(.failure(ProbeFailure("connection_closed", "Incomplete frame body.")))
                return
            }
            completion(.success(body))
        }
    }
}
