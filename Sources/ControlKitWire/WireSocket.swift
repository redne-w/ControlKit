import CryptoKit
import Darwin
import Foundation

/// Single-owner synchronous transport. A caller pumps its owned child through `progress`.
public final class WireSocket: @unchecked Sendable {
    let descriptor: Int32
    private var closed = false

    public init(owning descriptor: Int32) throws {
        self.descriptor = descriptor
        var enabled: Int32 = 1
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
            fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, 4) == 0
        else {
            Darwin.close(descriptor)
            throw WireFailure.socketFailure
        }
    }

    deinit { close() }

    public func close() {
        guard !closed else { return }
        Darwin.close(descriptor)
        closed = true
    }

    public func send(
        _ message: WireMessage, limit: Int, until deadline: ContinuousClock.Instant,
        progress: () throws -> Void = {}
    ) throws {
        guard (1...2 * 1_024 * 1_024).contains(limit), message.type.utf8.count <= 16,
            (message.token?.utf8.count ?? 0) <= 128, (message.operation?.utf8.count ?? 0) <= 64,
            (message.capabilities?.count ?? 0) <= 16,
            message.capabilities?.allSatisfy({ $0.utf8.count <= 128 }) ?? true
        else { throw WireFailure.invalidFrame }
        let payload = try JSONEncoder().encode(message)
        guard payload.count < limit else { throw WireFailure.invalidFrame }
        let frameDeadline = min(deadline, ContinuousClock.now.advanced(by: .seconds(5)))
        let count = UInt32(payload.count + 1)
        let header: [UInt8] = [
            UInt8(truncatingIfNeeded: count >> 24), UInt8(truncatingIfNeeded: count >> 16),
            UInt8(truncatingIfNeeded: count >> 8), UInt8(truncatingIfNeeded: count), 1,
        ]
        var data = Data(header)
        data.append(payload)
        var offset = 0
        while offset < data.count {
            try wait(POLLOUT, until: frameDeadline, progress: progress)
            let count = data.withUnsafeBytes {
                Darwin.send(
                    descriptor, $0.baseAddress!.advanced(by: offset), data.count - offset, 0)
            }
            if count < 0, errno == EAGAIN || errno == EINTR { continue }
            guard count > 0 else { throw WireFailure.disconnected }
            offset += count
        }
    }

    public func sendJSON<Value: Encodable>(
        _ value: Value, limit: Int, until deadline: ContinuousClock.Instant,
        progress: () throws -> Void = {}
    ) throws {
        guard (1...2 * 1_024 * 1_024).contains(limit) else { throw WireFailure.invalidFrame }
        let payload = try JSONEncoder().encode(value)
        guard payload.count < limit else { throw WireFailure.invalidFrame }
        try sendFrame(kind: 1, payload: payload, until: deadline, progress: progress)
    }

    public func receiveJSON<Value: Decodable>(
        _ type: Value.Type, limit: Int, until deadline: ContinuousClock.Instant,
        progress: () throws -> Void = {}
    ) throws -> Value {
        guard (1...2 * 1_024 * 1_024).contains(limit) else { throw WireFailure.invalidFrame }
        let frame = try receiveFrame(limit: limit, until: deadline, progress: progress)
        guard frame.kind == 1 else { throw WireFailure.invalidMessage }
        _ = try JSONShape.validate(
            frame.payload, maximumBytes: limit, maximumDepth: 32)
        guard
            let value = try? JSONDecoder().decode(type, from: frame.payload)
        else { throw WireFailure.invalidMessage }
        return value
    }

    public func receive(
        limit: Int, until deadline: ContinuousClock.Instant, progress: () throws -> Void = {}
    ) throws -> WireMessage {
        guard (1...2 * 1_024 * 1_024).contains(limit) else { throw WireFailure.invalidFrame }
        let frame = try receiveFrame(limit: limit, until: deadline, progress: progress)
        guard frame.kind == 1 else { throw WireFailure.invalidFrame }
        return try WireJSON.decode(frame.payload, maximumBytes: limit)
    }

    public func sendBinary(
        _ data: Data, until deadline: ContinuousClock.Instant,
        progress: () throws -> Void = {}
    ) throws {
        guard data.count <= 32 * 1_024 * 1_024 else { throw WireFailure.invalidFrame }
        var offset = 0
        while offset < data.count {
            let count = min(65_535, data.count - offset)
            try sendFrame(
                kind: 2, payload: data.subdata(in: offset..<(offset + count)),
                until: deadline, progress: progress)
            offset += count
        }
    }

    public func receiveBinary(
        count: Int, sha256: String, until deadline: ContinuousClock.Instant,
        progress: () throws -> Void = {}
    ) throws -> Data {
        guard (0...32 * 1_024 * 1_024).contains(count), sha256.utf8.count == 64 else {
            throw WireFailure.invalidFrame
        }
        var data = Data()
        while data.count < count {
            let frame = try receiveFrame(
                limit: min(65_536, count - data.count + 1),
                until: deadline, progress: progress)
            guard frame.kind == 2, !frame.payload.isEmpty,
                data.count + frame.payload.count <= count
            else { throw WireFailure.invalidFrame }
            data.append(frame.payload)
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == sha256 else { throw WireFailure.invalidFrame }
        return data
    }

    private func receiveFrame(
        limit: Int, until deadline: ContinuousClock.Instant, progress: () throws -> Void
    ) throws -> (kind: UInt8, payload: Data) {
        var header = try read(count: 1, until: deadline, progress: progress)
        let frameDeadline = min(deadline, ContinuousClock.now.advanced(by: .seconds(5)))
        header.append(try read(count: 3, until: frameDeadline, progress: progress))
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 1, length <= limit else { throw WireFailure.invalidFrame }
        let body = try read(count: Int(length), until: frameDeadline, progress: progress)
        guard let kind = body.first, kind == 1 || kind == 2 else { throw WireFailure.invalidFrame }
        return (kind, Data(body.dropFirst()))
    }

    private func sendFrame(
        kind: UInt8, payload: Data, until deadline: ContinuousClock.Instant,
        progress: () throws -> Void
    ) throws {
        let length = UInt32(payload.count + 1)
        let header: [UInt8] = [
            UInt8(truncatingIfNeeded: length >> 24), UInt8(truncatingIfNeeded: length >> 16),
            UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length), kind,
        ]
        var frame = Data(header)
        frame.append(payload)
        var offset = 0
        while offset < frame.count {
            try wait(POLLOUT, until: deadline, progress: progress)
            let count = frame.withUnsafeBytes {
                Darwin.send(
                    descriptor, $0.baseAddress!.advanced(by: offset), frame.count - offset, 0)
            }
            if count < 0, errno == EAGAIN || errno == EINTR { continue }
            guard count > 0 else { throw WireFailure.disconnected }
            offset += count
        }
    }

    public func wait(
        _ events: Int32, until deadline: ContinuousClock.Instant, progress: () throws -> Void
    ) throws {
        guard !closed else { throw WireFailure.disconnected }
        while true {
            try progress()
            guard ContinuousClock.now < deadline else { throw WireFailure.deadlineExceeded }
            var item = pollfd(fd: descriptor, events: Int16(events), revents: 0)
            let count = poll(&item, 1, 10)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw WireFailure.socketFailure }
            if count > 0 {
                if Int32(item.revents) & events != 0 { return }
                throw WireFailure.disconnected
            }
        }
    }

    private func read(
        count: Int, until deadline: ContinuousClock.Instant, progress: () throws -> Void
    ) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            try wait(POLLIN, until: deadline, progress: progress)
            let received = data.withUnsafeMutableBytes {
                recv(descriptor, $0.baseAddress!.advanced(by: offset), count - offset, 0)
            }
            if received < 0, errno == EAGAIN || errno == EINTR { continue }
            guard received > 0 else { throw WireFailure.disconnected }
            offset += received
        }
        return data
    }
}
