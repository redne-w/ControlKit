import Foundation
import Testing

@testable import ControlKitContractSpecification

struct SessionTests {
    private func command(
        _ kind: SessionModel.Kind = .mutation, id: UUID = UUID(), fingerprint: String = "payload-A"
    ) -> SessionModel.Command {
        SessionModel.Command(id: id, fingerprint: fingerprint, kind: kind)
    }

    @Test func admissionAndReceiptBounds() {
        var model = SessionModel(queueLimit: 1, receiptLimit: 2)
        model.ready()
        let first = command()
        #expect(model.admit(first, generation: 1) == .accepted)
        #expect(model.admit(command(), generation: 1) == .rejected("busy"))
        #expect(model.dispatch()?.id == first.id)
        let second = command()
        #expect(model.admit(second, generation: 1) == .accepted)
        model.finish(id: first.id, generation: 1, succeeded: true)
        _ = model.dispatch()
        model.finish(id: second.id, generation: 1, succeeded: true)
        #expect(model.admit(command(), generation: 1) == .rejected("session_limit"))
        #expect(model.receipts.count == 2)
    }

    @Test func duplicateNeverRedispatches() {
        var model = SessionModel()
        model.ready()
        let first = command()
        #expect(model.admit(first, generation: 1) == .accepted)
        #expect(model.admit(first, generation: 1) == .duplicate(.queued))
        _ = model.dispatch()
        #expect(model.admit(first, generation: 1) == .duplicate(.dispatched))
        model.finish(id: first.id, generation: 1, succeeded: true)
        #expect(model.admit(first, generation: 1) == .duplicate(.finished))
        #expect(model.dispatch() == nil)
        let conflict = command(id: first.id, fingerprint: "different-payload")
        #expect(model.admit(conflict, generation: 1) == .rejected("request_id_conflict"))
    }

    @Test func queuedTimeoutDoesNotFence() {
        var model = SessionModel()
        model.ready()
        let first = command()
        _ = model.admit(first, generation: 1)
        model.timeout(id: first.id)
        #expect(model.state == .ready)
        #expect(model.receipts[first.id]?.status == .notDispatched)
        #expect(model.dispatch() == nil)
    }

    @Test func unknownRequiresRetirementAndFreshObservation() {
        var model = SessionModel()
        model.ready()
        let first = command()
        let queued = command()
        _ = model.admit(first, generation: 1)
        _ = model.dispatch()
        _ = model.admit(queued, generation: 1)
        model.timeout(id: first.id)
        #expect(model.state == .fenced)
        #expect(model.receipts[first.id]?.status == .unknown)
        #expect(model.receipts[queued.id]?.status == .notDispatched)
        model.finish(id: first.id, generation: 1, succeeded: true)
        #expect(model.state == .fenced)
        let recoveryStarted = model.beginRecovery()
        #expect(recoveryStarted)
        let prematureRecovery = model.finishRecovery(oldRunnerRetired: false, newGeneration: 2)
        #expect(!prematureRecovery)
        #expect(model.state == .fenced)
        let recoveryRestarted = model.beginRecovery()
        #expect(recoveryRestarted)
        let recovered = model.finishRecovery(oldRunnerRetired: true, newGeneration: 2)
        #expect(recovered)
        #expect(model.admit(command(), generation: 1) == .rejected("stale_generation"))
        #expect(model.admit(command(), generation: 2) == .rejected("inspection_required"))
        let snapshot = command(.inspection)
        #expect(model.admit(snapshot, generation: 2) == .accepted)
        _ = model.dispatch()
        model.finish(id: first.id, generation: 1, succeeded: true)
        #expect(model.state == .executing)
        model.finish(id: snapshot.id, generation: 2, succeeded: true)
        #expect(model.state == .ready)
        #expect(model.admit(first, generation: 2) == .duplicate(.unknown))
    }

    @Test func failedInspectionKeepsMutationFence() {
        var model = SessionModel()
        model.ready()
        model.fence()
        let recoveryStarted = model.beginRecovery()
        #expect(recoveryStarted)
        let recovered = model.finishRecovery(oldRunnerRetired: true, newGeneration: 2)
        #expect(recovered)
        let snapshot = command(.inspection)
        _ = model.admit(snapshot, generation: 2)
        _ = model.dispatch()
        model.finish(id: snapshot.id, generation: 2, succeeded: false)
        #expect(model.state == .needsInspection)
        #expect(model.admit(command(), generation: 2) == .rejected("inspection_required"))
    }

    @Test func partialMutationFailureFencesSession() {
        var model = SessionModel()
        model.ready()
        let first = command()
        _ = model.admit(first, generation: 1)
        _ = model.dispatch()
        model.finish(id: first.id, generation: 1, succeeded: false, effectsUncertain: true)
        #expect(model.state == .fenced)
        #expect(model.receipts[first.id]?.status == .unknown)
        #expect(model.admit(command(), generation: 1) == .rejected("session_not_ready"))
    }

    @Test func leaseCannotReleaseBeforeRunnerRetirement() {
        var model = SessionModel()
        model.ready()
        let first = command()
        _ = model.admit(first, generation: 1)
        _ = model.dispatch()
        model.requestStop()
        let prematureStop = model.finishStop(runnerRetired: false)
        #expect(!prematureStop)
        #expect(model.state == .fenced)
        #expect(model.receipts[first.id]?.status == .unknown)
        model.requestStop()
        let stopped = model.finishStop(runnerRetired: true)
        #expect(stopped)
        #expect(model.state == .stopped)
        #expect(model.admit(command(), generation: 1) == .rejected("session_not_ready"))
    }
}
