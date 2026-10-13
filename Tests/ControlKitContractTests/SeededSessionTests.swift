import ControlKitCore
import ControlKitTestSupport
import Foundation
import Testing

@testable import ControlKitContractSpecification

struct SeededSessionTests {
    @Test func replayBoundedScenarios() throws {
        let seeds = try selectedSeeds()
        for seed in seeds {
            print("ControlKit model replay seed: \(seed)")
            var generator = SeededGenerator(seed: seed)
            var trace = ReplayTrace(seed: seed)
            for scenario in 0..<256 {
                let capacity = generator.index(upperBound: 8) + 1
                let outcome = generator.index(upperBound: 4)
                trace.record("scenario=\(scenario) capacity=\(capacity) outcome=\(outcome)")
                try exercise(capacity: capacity, outcome: outcome, trace: &trace)
            }
        }
    }

    private func selectedSeeds() throws -> [UInt64] {
        guard let text = ProcessInfo.processInfo.environment["CONTROLKIT_TEST_SEED"] else {
            return [0, 1, 42, 0xdead_beef, UInt64.max]
        }
        guard !text.isEmpty, text.utf8.count <= 20,
            text.utf8.allSatisfy({ (48...57).contains($0) }), let seed = UInt64(text)
        else { throw SeedFailure.invalidSeed }
        return [seed]
    }

    private func exercise(capacity: Int, outcome: Int, trace: inout ReplayTrace) throws {
        let context = Comment(rawValue: trace.report)
        var model = SessionModel(queueLimit: capacity)
        model.ready()
        var clock = ManualClock()
        let deadline = try Deadline(now: clock.now, timeoutMilliseconds: 30_000)
        let first = command(0)
        _ = model.admit(first, generation: 1)
        _ = model.dispatch()
        for index in 1...capacity { _ = model.admit(command(index), generation: 1) }
        #expect(model.admit(command(99), generation: 1) == .rejected("busy"), context)
        #expect(model.admit(first, generation: 1) == .duplicate(.dispatched), context)
        switch outcome {
        case 0:
            model.finish(id: first.id, generation: 1, succeeded: true)
            for index in 1...capacity {
                #expect(model.dispatch()?.id == command(index).id, context)
                model.finish(id: command(index).id, generation: 1, succeeded: true)
            }
            #expect(model.admit(first, generation: 1) == .duplicate(.finished), context)
        case 1:
            try clock.advance(milliseconds: 29_999)
            #expect(!deadline.isExpired(at: clock.now), context)
            try clock.advance(milliseconds: 1)
            #expect(deadline.isExpired(at: clock.now), context)
            model.timeout(id: first.id)
            try verifyRecovery(&model, first: first, trace: trace)
        case 2:
            model.finish(id: first.id, generation: 1, succeeded: false, effectsUncertain: true)
            try verifyRecovery(&model, first: first, trace: trace)
        default:
            model.timeout(id: command(capacity).id)
            #expect(model.state == .executing, context)
            #expect(model.receipts[command(capacity).id]?.status == .notDispatched, context)
            model.requestStop()
            let stopped = model.finishStop(runnerRetired: true)
            #expect(stopped, context)
        }
        model.checkInvariants()
        trace.record("terminal=\(model.state) generation=\(model.generation)")
    }

    private func verifyRecovery(
        _ model: inout SessionModel, first: SessionModel.Command, trace: ReplayTrace
    ) throws {
        let context = Comment(rawValue: trace.report)
        #expect(model.state == .fenced, context)
        #expect(model.queue.isEmpty, context)
        model.finish(id: first.id, generation: 1, succeeded: true)
        #expect(model.state == .fenced, context)
        let began = model.beginRecovery()
        #expect(began, context)
        let generation = try HelperGeneration(model.generation).successor()
        let recovered = model.finishRecovery(
            oldRunnerRetired: true, newGeneration: generation.value)
        #expect(recovered, context)
        #expect(
            model.admit(command(100), generation: 2) == .rejected("inspection_required"),
            context)
        let observation = command(101, kind: .inspection)
        _ = model.admit(observation, generation: 2)
        _ = model.dispatch()
        model.finish(id: observation.id, generation: 1, succeeded: true)
        #expect(model.state == .executing, context)
        model.finish(id: observation.id, generation: 2, succeeded: true)
        #expect(model.state == .ready, context)
        #expect(model.admit(first, generation: 2) == .duplicate(.unknown), context)
    }

    private func command(_ value: Int, kind: SessionModel.Kind = .mutation) -> SessionModel.Command
    {
        precondition((0...255).contains(value))
        let id = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(value)))
        return SessionModel.Command(id: id, fingerprint: "payload-\(value)", kind: kind)
    }
}

private enum SeedFailure: Error {
    case invalidSeed
}
