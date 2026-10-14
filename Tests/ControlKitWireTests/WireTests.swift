import CryptoKit
import Darwin
import Foundation
import Testing

@testable import ControlKitWire

struct WireTests {
    private func identity() -> WireIdentity {
        WireIdentity(epoch: UUID(), session: UUID(), generation: 1, launch: UUID())
    }

    private func largeInspectResult() -> UIResult {
        let node = UINode(
            reference: UUID().uuidString, parent: 0, elementType: 48,
            identifier: "", label: String(repeating: "x", count: 4_096), value: nil,
            enabled: true, selected: false,
            frame: UIFrame(x: 0, y: 0, width: 100, height: 20), truncatedAttributes: [])
        let nodes = Array(repeating: node, count: 20)
        var result = UIResult()
        result.snapshot = UISnapshot(
            id: UUID(), capturedMonotonicMilliseconds: 1,
            bundleIdentifier: "com.example.fixture", generation: 1, orientation: 1,
            coordinateSpace: "screen_points", screenWidthPoints: 390, screenHeightPoints: 844,
            nodes: nodes, truncated: false, truncationReasons: [],
            visitedCount: nodes.count, emittedCount: nodes.count)
        return result
    }

    private func pair() throws -> (WireSocket, WireSocket) {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw WireFailure.socketFailure
        }
        return (try WireSocket(owning: descriptors[0]), try WireSocket(owning: descriptors[1]))
    }

    @Test func listenerKeepsPortAndHelperConnectsOutward() throws {
        let listener = try WireListener()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        let helper = try WireListener.connect(port: listener.port, until: deadline)
        let host = try listener.accept(until: deadline)
        listener.close()
        var request = WireMessage(type: "request", identity: identity())
        request.requestId = UUID()
        request.operation = "lifecycle.ping"
        request.remainingMilliseconds = 1_000
        try host.send(request, limit: 4_096, until: deadline)
        let received = try helper.receive(limit: 4_096, until: deadline)
        #expect(received.requestId == request.requestId)
    }

    @Test func invalidLengthsKindsAndTruncation() throws {
        for bytes: [UInt8] in [
            [0, 0, 0, 0], [0, 0, 0, 1], [255, 255, 255, 255], [0, 0, 0, 2, 2, 0],
        ] {
            let (writer, reader) = try pair()
            _ = bytes.withUnsafeBytes {
                Darwin.send(writer.descriptor, $0.baseAddress!, $0.count, 0)
            }
            #expect(throws: WireFailure.invalidFrame) {
                _ = try reader.receive(limit: 4_096, until: .now.advanced(by: .seconds(10)))
            }
        }
        let (writer, reader) = try pair()
        let bytes: [UInt8] = [0, 0, 0, 8, 1]
        _ = bytes.withUnsafeBytes { Darwin.send(writer.descriptor, $0.baseAddress!, $0.count, 0) }
        writer.close()
        #expect(throws: WireFailure.disconnected) {
            _ = try reader.receive(limit: 4_096, until: .now.advanced(by: .seconds(10)))
        }
    }

    @Test func stalledPeerAndProgressDeadline() throws {
        let (writer, reader) = try pair()
        defer { writer.close() }
        #expect(throws: WireFailure.deadlineExceeded) {
            _ = try reader.receive(limit: 4_096, until: .now.advanced(by: .milliseconds(20)))
        }
    }

    @Test func authenticationRejectsWrongLaunchDeviceAndToken() throws {
        let identity = identity()
        let device = UUID()
        let token = String(repeating: "a", count: 64)
        var hello = WireMessage(type: "hello", identity: identity)
        hello.token = token
        hello.helperPID = 123
        hello.simulatorUDID = device
        hello.capabilities = WireMessage.lifecycleCapabilities
        try hello.validateHello(identity: identity, token: token, device: device)
        #expect(throws: WireFailure.authenticationFailed) {
            try hello.validateHello(
                identity: identity, token: String(repeating: "b", count: 64), device: device)
        }
        #expect(throws: WireFailure.identityMismatch) {
            try hello.validateHello(identity: self.identity(), token: token, device: device)
        }
        #expect(throws: WireFailure.identityMismatch) {
            try hello.validateHello(identity: identity, token: token, device: UUID())
        }
        hello.protocolVersion = 2
        #expect(throws: WireFailure.protocolMismatch) {
            try hello.validateHello(identity: identity, token: token, device: device)
        }
    }

    @Test func fragmentedFrameAndDuplicateEscapedKey() throws {
        let (writer, reader) = try pair()
        var message = WireMessage(type: "request", identity: identity())
        message.operation = "lifecycle.ping"
        message.requestId = UUID()
        message.remainingMilliseconds = 1_000
        let payload = try JSONEncoder().encode(message)
        let length = UInt32(payload.count + 1)
        var bytes: [UInt8] = [
            UInt8(truncatingIfNeeded: length >> 24), UInt8(truncatingIfNeeded: length >> 16),
            UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length), 1,
        ]
        bytes.append(contentsOf: payload)
        var cursor = 0
        let received = try reader.receive(limit: 4_096, until: .now.advanced(by: .seconds(10))) {
            if cursor < bytes.count {
                var byte = bytes[cursor]
                #expect(Darwin.send(writer.descriptor, &byte, 1, 0) == 1)
                cursor += 1
            }
        }
        #expect(received.requestId == message.requestId)
        let duplicate = String(decoding: payload, as: UTF8.self).replacingOccurrences(
            of: #""type":"request""#, with: #""type":"hello","ty\u0070e":"request""#)
        #expect(throws: WireFailure.invalidMessage) {
            _ = try WireJSON.decode(Data(duplicate.utf8))
        }
        #expect(throws: WireFailure.invalidMessage) { _ = try WireJSON.decode(Data([0xff])) }
    }

    @Test func rejectsUnknownKeysAndDeepJSON() throws {
        var message = WireMessage(type: "request", identity: identity())
        message.requestId = UUID()
        message.operation = "lifecycle.ping"
        message.remainingMilliseconds = 1_000
        let data = try JSONEncoder().encode(message)
        _ = try WireJSON.decode(data)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["unknown"] = true
        #expect(throws: WireFailure.invalidMessage) {
            _ = try WireJSON.decode(JSONSerialization.data(withJSONObject: object))
        }
        let deep = Data(
            (String(repeating: "[", count: 9) + "0"
                + String(repeating: "]", count: 9)).utf8)
        #expect(throws: WireFailure.invalidMessage) { _ = try WireJSON.decode(deep) }
    }

    @Test func receiveHonorsLargeReplyPhaseLimit() throws {
        let (writer, reader) = try pair()
        var reply = WireMessage(type: "reply", identity: identity())
        reply.requestId = UUID()
        reply.operation = "ui.inspect"
        reply.result = largeInspectResult()
        // Generous: these check correctness, and shared CI machines run tests slowly in parallel.
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        let sent = DispatchSemaphore(value: 0)
        let sentReply = reply
        DispatchQueue.global().async {
            try? writer.send(sentReply, limit: 2 * 1_024 * 1_024, until: deadline)
            sent.signal()
        }
        let received = try reader.receive(
            limit: 2 * 1_024 * 1_024, until: deadline)
        #expect(received.result?.snapshot?.nodes.count == 20)
        #expect(sent.wait(timeout: .now() + 10) == .success)
    }

    @Test func binaryArtifactRoundTripAndDigestFailure() throws {
        let data = Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0) })
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let (writer, reader) = try pair()
        // Generous: these check correctness, and shared CI machines run tests slowly in parallel.
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        let sent = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? writer.sendBinary(data, until: deadline)
            sent.signal()
        }
        let received = try reader.receiveBinary(
            count: data.count, sha256: digest, until: deadline)
        #expect(received == data)
        #expect(sent.wait(timeout: .now() + 10) == .success)

        let (badWriter, badReader) = try pair()
        DispatchQueue.global().async {
            try? badWriter.sendBinary(data, until: deadline)
        }
        #expect(throws: WireFailure.invalidFrame) {
            _ = try badReader.receiveBinary(
                count: data.count, sha256: String(repeating: "0", count: 64), until: deadline)
        }
    }

    @Test func selectorFamiliesAndOperationArgumentsAreStrict() throws {
        var selector = UISelector()
        #expect(throws: WireFailure.invalidMessage) { try selector.validate() }
        selector.elementType = 49
        try selector.validate()
        selector.elementType = nil
        selector.identifier = "submit"
        try selector.validate()
        selector.label = "Submit"
        #expect(throws: WireFailure.invalidMessage) { try selector.validate() }
        selector.label = nil
        selector.snapshotId = UUID()
        #expect(throws: WireFailure.invalidMessage) { try selector.validate() }

        var parameters = UIParameters()
        parameters.selector = {
            var value = UISelector()
            value.identifier = "field"
            return value
        }()
        #expect(throws: WireFailure.invalidMessage) {
            try parameters.validate(operation: "ui.type")
        }
        parameters.text = "literal"
        try parameters.validate(operation: "ui.type")
        parameters.text = ""
        #expect(throws: WireFailure.invalidMessage) {
            try parameters.validate(operation: "ui.type")
        }
        #expect(throws: WireFailure.invalidMessage) {
            try parameters.validate(operation: "ui.set_text")
        }
        #expect(throws: WireFailure.invalidMessage) {
            _ = try JSONDecoder().decode(
                UIParameters.self, from: Data(#"{"text":"literal","unknown":true}"#.utf8))
        }
    }

    @Test func coordinatesAndSystemAlertSelectorsAreOperationScoped() throws {
        var coordinate = UISelector()
        coordinate.x = 10
        coordinate.y = 20
        coordinate.snapshotId = UUID()
        var parameters = UIParameters()
        parameters.selector = coordinate
        parameters.text = "value"
        try parameters.validate(operation: "ui.type")
        try parameters.validate(operation: "ui.set_text")
        parameters.text = nil
        #expect(throws: WireFailure.invalidMessage) {
            try parameters.validate(operation: "ui.find")
        }

        var alert = UISelector()
        alert.label = "Allow"
        parameters.selector = alert
        try parameters.validate(operation: "ui.system_alert.tap")
        alert.elementType = 9
        parameters.selector = alert
        #expect(throws: WireFailure.invalidMessage) {
            try parameters.validate(operation: "ui.system_alert.tap")
        }
    }
}
