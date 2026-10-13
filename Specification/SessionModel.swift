import Foundation

/// An executable safety specification. No transport, processes, timers, or XCTest live here.
/// Tests supply external facts; they do NOT prove that killing XCTest cancels Apple's work.
struct SessionModel {
    enum State: String {
        case starting, ready, executing, fenced, recovering, needsInspection, stopping, stopped
    }

    enum Kind { case inspection, read, mutation }
    enum Status: Equatable { case queued, dispatched, finished, notDispatched, unknown }

    struct Command {
        let id: UUID
        let fingerprint: String
        let kind: Kind
    }

    struct Receipt {
        let command: Command
        var status: Status
    }

    enum Admission: Equatable {
        case accepted
        case duplicate(Status)
        case rejected(String)
    }

    private(set) var state = State.starting
    private(set) var generation: UInt64 = 1
    private(set) var receipts: [UUID: Receipt] = [:]
    private(set) var queue: [Command] = []
    private(set) var active: Command?
    private var recoveryInspection = false
    let queueLimit: Int
    let receiptLimit: Int

    init(queueLimit: Int = 8, receiptLimit: Int = 10_000) {
        precondition((1...8).contains(queueLimit))
        precondition((1...10_000).contains(receiptLimit))
        self.queueLimit = queueLimit
        self.receiptLimit = receiptLimit
    }

    mutating func ready() {
        precondition(state == .starting)
        state = .ready
        checkInvariants()
    }

    mutating func admit(_ command: Command, generation expected: UInt64) -> Admission {
        defer { checkInvariants() }
        guard expected == generation else { return .rejected("stale_generation") }
        if let receipt = receipts[command.id] {
            guard receipt.command.fingerprint == command.fingerprint else {
                return .rejected("request_id_conflict")
            }
            return .duplicate(receipt.status)
        }
        guard state == .ready || state == .executing || state == .needsInspection else {
            return .rejected("session_not_ready")
        }
        if state == .needsInspection || recoveryInspection {
            guard command.kind == .inspection else { return .rejected("inspection_required") }
        }
        guard receipts.count < receiptLimit else { return .rejected("session_limit") }
        guard queue.count < queueLimit else { return .rejected("busy") }
        receipts[command.id] = Receipt(command: command, status: .queued)
        queue.append(command)
        return .accepted
    }

    mutating func dispatch() -> Command? {
        defer { checkInvariants() }
        guard state == .ready || state == .needsInspection, !queue.isEmpty else { return nil }
        precondition(active == nil)
        recoveryInspection = state == .needsInspection
        let command = queue.removeFirst()
        active = command
        receipts[command.id]!.status = .dispatched
        state = .executing
        return command
    }

    /// Ignore stale and duplicate completions. A late result never silently unfences a session.
    mutating func finish(
        id: UUID, generation completed: UInt64, succeeded: Bool, effectsUncertain: Bool = false
    ) {
        defer { checkInvariants() }
        guard completed == generation, state == .executing, active?.id == id else { return }
        if effectsUncertain {
            fence()
            return
        }
        receipts[id]!.status = .finished
        active = nil
        state = recoveryInspection && !succeeded ? .needsInspection : .ready
        recoveryInspection = state == .needsInspection
    }

    mutating func timeout(id: UUID) {
        defer { checkInvariants() }
        if let index = queue.firstIndex(where: { $0.id == id }) {
            queue.remove(at: index)
            receipts[id]!.status = .notDispatched
        } else if state == .executing, active?.id == id {
            fence()
        }
    }

    mutating func fence() {
        precondition(state != .stopped)
        if let active { receipts[active.id]!.status = .unknown }
        cancelQueued()
        state = .fenced
        checkInvariants()
    }

    mutating func beginRecovery() -> Bool {
        guard state == .fenced else { return false }
        state = .recovering
        checkInvariants()
        return true
    }

    mutating func finishRecovery(oldRunnerRetired: Bool, newGeneration: UInt64) -> Bool {
        defer { checkInvariants() }
        guard state == .recovering, generation < UInt64.max,
            newGeneration == generation + 1
        else { return false }
        guard oldRunnerRetired else {
            state = .fenced
            return false
        }
        generation = newGeneration
        active = nil
        recoveryInspection = true
        state = .needsInspection
        return true
    }

    mutating func requestStop() {
        guard state != .stopped else { return }
        if let active { receipts[active.id]!.status = .unknown }
        cancelQueued()
        state = .stopping
        checkInvariants()
    }

    mutating func finishStop(runnerRetired: Bool) -> Bool {
        defer { checkInvariants() }
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

    private mutating func cancelQueued() {
        for command in queue { receipts[command.id]!.status = .notDispatched }
        queue.removeAll(keepingCapacity: true)
    }

    func checkInvariants() {
        precondition(queue.count <= queueLimit)
        precondition(receipts.count <= receiptLimit)
        precondition(generation > 0)
        if state == .executing { precondition(active != nil) }
        if let active {
            precondition([.executing, .fenced, .recovering, .stopping].contains(state))
            precondition(!queue.contains(where: { $0.id == active.id }))
        }
        for command in queue {
            precondition(receipts[command.id]?.status == .queued)
        }
        if [.fenced, .recovering, .stopping, .stopped].contains(state) {
            precondition(queue.isEmpty)
        }
    }
}
