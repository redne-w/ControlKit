import Foundation

/// Pure synchronous transitions. Process/network effects occur only after returned dispatch intent.
package struct SessionMachine: Sendable {
    package private(set) var state: SessionState = .starting
    package private(set) var generation: UInt64 = 1
    package private(set) var receipts: [UUID: SessionReceipt] = [:]
    package private(set) var queue: [SessionCommand] = []
    package private(set) var active: SessionCommand?
    package private(set) var snapshot: UUID?
    private var recoveryInspection = false
    private let queueLimit: Int
    private let receiptLimit: Int

    package init(queueLimit: Int = 8, receiptLimit: Int = 10_000) {
        precondition((1...8).contains(queueLimit))
        precondition((1...10_000).contains(receiptLimit))
        self.queueLimit = queueLimit
        self.receiptLimit = receiptLimit
    }

    package mutating func markReady() {
        precondition(state == .starting)
        state = .ready
        check()
    }

    package mutating func admit(_ command: SessionCommand, generation expected: UInt64)
        -> SessionAdmission
    {
        defer { check() }
        guard expected == generation else { return .rejected("stale_generation") }
        if let receipt = receipts[command.id] {
            guard receipt.fingerprint == command.fingerprint else {
                return .rejected("request_id_conflict")
            }
            return .duplicate(receipt.status)
        }
        guard state == .ready || state == .executing || state == .needsInspection else {
            return .rejected("session_not_ready")
        }
        if state == .needsInspection || recoveryInspection {
            guard command.operation.isInspection else { return .rejected("inspection_required") }
        }
        guard receipts.count < receiptLimit else { return .rejected("session_limit") }
        guard queue.count < queueLimit else { return .rejected("busy") }
        receipts[command.id] = SessionReceipt(
            requestId: command.id, fingerprint: command.fingerprint,
            operation: command.operation, status: .queued, resultAvailable: false)
        queue.append(command)
        return .accepted
    }

    package mutating func dispatch(now: ContinuousClock.Instant) -> SessionCommand? {
        defer { check() }
        guard state == .ready || state == .needsInspection, active == nil else { return nil }
        while let first = queue.first, first.deadline <= now {
            expireQueued(id: first.id)
        }
        guard !queue.isEmpty else { return nil }
        recoveryInspection = state == .needsInspection
        let command = queue.removeFirst()
        active = command
        receipts[command.id]!.status = .dispatched
        state = .executing
        if command.operation.isMutation { snapshot = nil }
        return command
    }

    package mutating func finish(
        id: UUID, generation completed: UInt64, succeeded: Bool, errorCode: String? = nil,
        resultAvailable: Bool = true, effectsUncertain: Bool = false,
        snapshot newSnapshot: UUID? = nil
    ) {
        defer { check() }
        guard completed == generation, state == .executing, active?.id == id else { return }
        if effectsUncertain {
            fence(errorCode: "outcome_unknown")
            return
        }
        receipts[id]!.status = .finished
        receipts[id]!.errorCode = errorCode
        receipts[id]!.resultAvailable = resultAvailable
        if succeeded, active?.operation.isInspection == true { snapshot = newSnapshot }
        active = nil
        state = recoveryInspection && !succeeded ? .needsInspection : .ready
        recoveryInspection = state == .needsInspection
    }

    package mutating func timeout(id: UUID) {
        defer { check() }
        if queue.contains(where: { $0.id == id }) {
            expireQueued(id: id)
        } else if state == .executing, active?.id == id {
            fence(errorCode: "outcome_unknown")
        }
    }

    package mutating func beginRecovery() -> Bool {
        guard state == .fenced else { return false }
        state = .recovering
        snapshot = nil
        check()
        return true
    }

    package mutating func finishRecovery(oldRunnerRetired: Bool) -> Bool {
        defer { check() }
        guard state == .recovering, generation < UInt64.max else { return false }
        guard oldRunnerRetired else {
            state = .fenced
            return false
        }
        generation += 1
        active = nil
        recoveryInspection = true
        state = .needsInspection
        return true
    }

    package mutating func requestStop() {
        guard state != .stopped else { return }
        if let active {
            receipts[active.id]!.status = .unknown
            receipts[active.id]!.errorCode = "outcome_unknown"
        }
        cancelQueued()
        snapshot = nil
        state = .stopping
        check()
    }

    package mutating func finishStop(runnerRetired: Bool) -> Bool {
        defer { check() }
        guard state == .stopping else { return false }
        guard runnerRetired else {
            state = .fenced
            return false
        }
        active = nil
        recoveryInspection = false
        state = .stopped
        return true
    }

    package mutating func invalidateSnapshot() { snapshot = nil }

    package mutating func markResultExpired(id: UUID) {
        guard receipts[id]?.status == .finished else { return }
        receipts[id]!.resultAvailable = false
    }

    package mutating func markFinishedError(id: UUID, code: String) {
        guard receipts[id]?.status == .finished else { return }
        receipts[id]!.errorCode = code
        receipts[id]!.resultAvailable = false
    }

    package mutating func failStartup() {
        precondition(state == .starting)
        state = .fenced
        check()
    }

    package mutating func failRecovery() {
        precondition(state == .recovering)
        state = .fenced
        check()
    }

    private mutating func fence(errorCode: String) {
        if let active {
            receipts[active.id]!.status = .unknown
            receipts[active.id]!.errorCode = errorCode
        }
        cancelQueued()
        snapshot = nil
        state = .fenced
    }

    private mutating func expireQueued(id: UUID) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue.remove(at: index)
        receipts[id]!.status = .notDispatched
        receipts[id]!.errorCode = "deadline_exceeded"
    }

    private mutating func cancelQueued() {
        for command in queue {
            receipts[command.id]!.status = .notDispatched
            receipts[command.id]!.errorCode = "cancelled"
        }
        queue.removeAll(keepingCapacity: true)
    }

    private func check() {
        precondition(queue.count <= queueLimit && receipts.count <= receiptLimit)
        precondition(generation > 0)
        precondition(
            (state == .executing) == (active != nil) || state == .fenced
                || state == .recovering || state == .stopping)
        if [.fenced, .recovering, .stopping, .stopped].contains(state) {
            precondition(queue.isEmpty)
        }
        for command in queue { precondition(receipts[command.id]?.status == .queued) }
    }
}
