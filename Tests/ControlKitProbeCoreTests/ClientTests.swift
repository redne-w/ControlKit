import Foundation
import Testing

@testable import ControlKitProbeCore

struct ClientTests {
    @Test(arguments: [0.0, -1.0, 120.1, Double.infinity, Double.nan])
    func rejectInvalidDeadline(seconds: Double) {
        let request = ProbeRequest(token: String(repeating: "x", count: 32), operation: .ping)
        #expect(throws: ProbeFailure.self) {
            try ProbeClient.send(request, port: 49200, timeoutSeconds: seconds)
        }
    }

    @Test func rejectZeroPort() {
        let request = ProbeRequest(token: String(repeating: "x", count: 32), operation: .ping)
        #expect(throws: ProbeFailure.self) {
            try ProbeClient.send(request, port: 0, timeoutSeconds: 1)
        }
    }

    @Test(arguments: [
        "{}", "{\"operation\":\"not-an-operation\"}",
        "{\"version\":1,\"id\":12,\"token\":false,\"operation\":\"ping\"}",
    ])
    func rejectMalformedRequests(json: String) {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ProbeRequest.self, from: Data(json.utf8))
        }
    }
}
