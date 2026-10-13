import Foundation

// Milestone-2 reference schema, not a production protocol implementation.
enum Completion: String, Codable {
    case notDispatched = "not_dispatched"
    case finished
    case unknown
}

struct ResultError: Codable, Equatable {
    let code: String
    let message: String
}

struct ResultEnvelope: Codable {
    let schemaVersion: UInt32
    let requestId: UUID
    let supervisorEpoch: UUID?
    let sessionId: UUID?
    let helperGeneration: UInt64?
    let ok: Bool
    let completion: Completion
    let error: ResultError?

    func validate() throws {
        guard schemaVersion == 1 else { throw ContractViolation.unsupportedVersion }
        guard ok == (error == nil) else { throw ContractViolation.inconsistentResult }
        if ok {
            guard completion == .finished else { throw ContractViolation.inconsistentResult }
        }
        if completion == .unknown {
            guard error?.code == "outcome_unknown" else {
                throw ContractViolation.inconsistentResult
            }
        } else if error?.code == "outcome_unknown" {
            throw ContractViolation.inconsistentResult
        }
        if let helperGeneration {
            guard sessionId != nil, supervisorEpoch != nil, helperGeneration > 0 else {
                throw ContractViolation.inconsistentResult
            }
        }
    }
}

enum ContractViolation: Error {
    case unsupportedVersion
    case inconsistentResult
}
