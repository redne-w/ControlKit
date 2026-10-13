import Foundation
import Testing

@testable import ControlKitSession

struct SessionMachineTests {
    private func command(
        _ operation: SessionOperation = .tap, id: UUID = UUID(),
        deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(10))
    ) -> SessionCommand {
        SessionCommand(
            id: id, fingerprint: "\(operation.rawValue)-\(id)", operation: operation,
            deadline: deadline)
    }

    @Test func boundedAdmissionDuplicateAndConflict() {
        var machine = SessionMachine(queueLimit: 1, receiptLimit: 2)
        machine.markReady()
        let first = command()
        #expect(machine.admit(first, generation: 1) == .accepted)
        #expect(machine.admit(first, generation: 1) == .duplicate(.queued))
        let conflict = SessionCommand(
            id: first.id, fingerprint: "different", operation: .tap, deadline: first.deadline)
        #expect(machine.admit(conflict, generation: 1) == .rejected("request_id_conflict"))
        #expect(machine.admit(command(), generation: 1) == .rejected("busy"))
        #expect(machine.admit(command(), generation: 2) == .rejected("stale_generation"))
    }

    @Test func queuedExpiryNeverFences() {
        var machine = SessionMachine()
        machine.markReady()
        let expired = command(deadline: .now)
        #expect(machine.admit(expired, generation: 1) == .accepted)
        #expect(machine.dispatch(now: .now) == nil)
        #expect(machine.receipts[expired.id]?.status == .notDispatched)
        #expect(machine.state == .ready)
    }

    @Test func dispatchedUncertaintyFencesAndCancelsQueue() {
        var machine = SessionMachine()
        machine.markReady()
        let active = command()
        let waiting = command()
        #expect(machine.admit(active, generation: 1) == .accepted)
        _ = machine.dispatch(now: .now)
        #expect(machine.admit(waiting, generation: 1) == .accepted)
        machine.timeout(id: active.id)
        #expect(machine.state == .fenced)
        #expect(machine.receipts[active.id]?.status == .unknown)
        #expect(machine.receipts[waiting.id]?.status == .notDispatched)
    }

    @Test func recoveryRequiresInspectionAndNewGeneration() {
        var machine = SessionMachine()
        machine.markReady()
        let uncertain = command()
        _ = machine.admit(uncertain, generation: 1)
        _ = machine.dispatch(now: .now)
        machine.finish(id: uncertain.id, generation: 1, succeeded: false, effectsUncertain: true)
        let beganFirst = machine.beginRecovery()
        let failedFirst = machine.finishRecovery(oldRunnerRetired: false)
        let beganSecond = machine.beginRecovery()
        let finishedSecond = machine.finishRecovery(oldRunnerRetired: true)
        #expect(beganFirst)
        #expect(!failedFirst)
        #expect(beganSecond)
        #expect(finishedSecond)
        #expect(machine.generation == 2)
        #expect(machine.state == .needsInspection)
        #expect(machine.admit(command(), generation: 2) == .rejected("inspection_required"))
        let inspect = command(.inspect)
        #expect(machine.admit(inspect, generation: 2) == .accepted)
        _ = machine.dispatch(now: .now)
        let snapshot = UUID()
        machine.finish(
            id: inspect.id, generation: 2, succeeded: true, snapshot: snapshot)
        #expect(machine.state == .ready)
        #expect(machine.snapshot == snapshot)
    }

    @Test func staleCompletionCannotFinishNewGeneration() {
        var machine = SessionMachine()
        machine.markReady()
        let first = command()
        _ = machine.admit(first, generation: 1)
        _ = machine.dispatch(now: .now)
        machine.timeout(id: first.id)
        _ = machine.beginRecovery()
        _ = machine.finishRecovery(oldRunnerRetired: true)
        let inspect = command(.inspect)
        _ = machine.admit(inspect, generation: 2)
        _ = machine.dispatch(now: .now)
        machine.finish(id: inspect.id, generation: 1, succeeded: true, snapshot: UUID())
        #expect(machine.state == .executing)
        #expect(machine.active?.id == inspect.id)
    }

    @Test func stopRetainsLeaseUntilRetirement() {
        var machine = SessionMachine()
        machine.markReady()
        machine.requestStop()
        let failed = machine.finishStop(runnerRetired: false)
        #expect(!failed)
        #expect(machine.state == .fenced)
        var clean = SessionMachine()
        clean.markReady()
        clean.requestStop()
        let finished = clean.finishStop(runnerRetired: true)
        #expect(finished)
        #expect(clean.state == .stopped)
    }

    @Test func extendedOperationsKeepRecoveryAndMutationSemantics() {
        #expect(SessionOperation.inspect.isInspection)
        #expect(!SessionOperation.find.isInspection)
        #expect(!SessionOperation.systemAlertInspect.isInspection)
        #expect(SessionOperation.setText.isMutation)
        #expect(SessionOperation.systemAlertTap.isMutation)
        #expect(!SessionOperation.find.isMutation)
        #expect(!SessionOperation.systemAlertInspect.isMutation)
    }
}
