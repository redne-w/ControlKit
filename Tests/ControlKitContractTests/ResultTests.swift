import Foundation
import Testing

@testable import ControlKitContractSpecification

struct ResultTests {
    @Test(arguments: ["succeeded", "not-dispatched", "outcome-unknown"])
    func examplesValidate(name: String) throws {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
        )
        let result = try JSONDecoder().decode(ResultEnvelope.self, from: Data(contentsOf: url))
        try result.validate()
        let decoded = try JSONDecoder().decode(
            ResultEnvelope.self, from: JSONEncoder().encode(result)
        )
        #expect(decoded.requestId == result.requestId)
        #expect(decoded.completion == result.completion)
    }

    @Test(arguments: [Completion.notDispatched, .finished, .unknown])
    func successRequiresFinished(completion: Completion) throws {
        let result = ResultEnvelope(
            schemaVersion: 1, requestId: UUID(), supervisorEpoch: nil, sessionId: nil,
            helperGeneration: nil, ok: true, completion: completion, error: nil
        )
        if completion == .finished {
            try result.validate()
        } else {
            #expect(throws: ContractViolation.self) { try result.validate() }
        }
    }

    @Test func unknownRequiresMatchingErrorCode() {
        let result = ResultEnvelope(
            schemaVersion: 1, requestId: UUID(), supervisorEpoch: UUID(), sessionId: UUID(),
            helperGeneration: 1, ok: false, completion: .unknown,
            error: ResultError(code: "element_not_found", message: "Wrong classification.")
        )
        #expect(throws: ContractViolation.self) { try result.validate() }
    }
}
