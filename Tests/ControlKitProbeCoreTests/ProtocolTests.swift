import Foundation
import Testing

@testable import ControlKitProbeCore

// These tests exercise exact boundaries, not only ordinary example requests.
struct ProtocolTests {
    private let token = String(repeating: "x", count: 32)

    @Test(arguments: [1, 255, 256, 65_535, 65_536])
    func frameRoundTrip(count: Int) throws {
        let body = Data(repeating: 42, count: count)
        let frame = try ProbeWire.frame(body, limit: ProbeLimits.requestBytes)
        #expect(frame.count == count + 4)
        #expect(try ProbeWire.length(frame.prefix(4), limit: ProbeLimits.requestBytes) == count)
        #expect(frame.dropFirst(4) == body)
    }

    @Test(arguments: [0, 65_537])
    func rejectInvalidBodyLength(count: Int) {
        #expect(throws: ProbeFailure.self) {
            try ProbeWire.frame(Data(repeating: 0, count: count), limit: ProbeLimits.requestBytes)
        }
    }

    @Test(arguments: [
        Data(), Data([0, 0, 1]), Data([0, 0, 0, 0]),
        Data([0, 1, 0, 1]), Data([255, 255, 255, 255]), Data([0, 0, 0, 1, 0]),
    ])
    func rejectInvalidHeader(header: Data) {
        #expect(throws: ProbeFailure.self) {
            try ProbeWire.length(header, limit: ProbeLimits.requestBytes)
        }
    }

    @Test(arguments: [31, 32, 128, 129])
    func tokenBoundaries(count: Int) throws {
        let request = ProbeRequest(token: String(repeating: "x", count: count), operation: .ping)
        if (32...128).contains(count) {
            try request.validate()
        } else {
            #expect(throws: ProbeFailure.self) { try request.validate() }
        }
    }

    @Test func requestRoundTripWithUnicode() throws {
        let request = ProbeRequest(
            token: token, operation: .type, identifier: "input", text: "Hello café 👋\n世界"
        )
        try request.validate()
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ProbeRequest.self, from: data)
        #expect(decoded.id == request.id)
        #expect(decoded.text == request.text)
    }

    @Test func rejectUnsupportedVersion() {
        var request = ProbeRequest(token: token, operation: .ping)
        request.version = 2
        #expect(throws: ProbeFailure("unsupported_version", "Expected probe protocol version 1.")) {
            try request.validate()
        }
    }

    @Test(arguments: ProbeOperation.allCases)
    func requiredArguments(operation: ProbeOperation) throws {
        var request = ProbeRequest(token: token, operation: operation)
        switch operation {
        case .tap, .swipe:
            #expect(throws: ProbeFailure.self) { try request.validate() }
            request.identifier = "element"
        case .type:
            #expect(throws: ProbeFailure.self) { try request.validate() }
            request.identifier = "input"
            #expect(throws: ProbeFailure.self) { try request.validate() }
            request.text = ""
        case .ping, .inspect, .screenshot, .stop:
            break
        }
        try request.validate()
    }

    @Test(arguments: [0, 4_096, 4_097])
    func identifierBoundaries(count: Int) throws {
        let request = ProbeRequest(
            token: token, operation: .tap, identifier: String(repeating: "x", count: count)
        )
        if count == 4_096 {
            try request.validate()
        } else {
            #expect(throws: ProbeFailure.self) { try request.validate() }
        }
    }

    @Test func rejectExtraneousArguments() {
        let request = ProbeRequest(token: token, operation: .inspect, text: "unused")
        #expect(throws: ProbeFailure.self) { try request.validate() }
    }

    @Test(arguments: [0, 4_096, 4_097])
    func textBoundaries(count: Int) throws {
        let request = ProbeRequest(
            token: token, operation: .type, identifier: "input",
            text: String(repeating: "é", count: count)
        )
        if count <= 4_096 {
            try request.validate()
        } else {
            #expect(throws: ProbeFailure.self) { try request.validate() }
        }
    }

    @Test func responseRoundTrip() throws {
        var response = ProbeResponse(id: UUID())
        response.ok = false
        response.error = ProbeFailure("element_not_found", "No match.")
        let decoded = try JSONDecoder().decode(
            ProbeResponse.self, from: JSONEncoder().encode(response)
        )
        #expect(decoded.id == response.id)
        #expect(decoded.error == response.error)
        #expect(!decoded.ok)
    }
}
