import Foundation
import Testing

@testable import ControlKitSession

struct SeededSessionMachineTests {
    @Test func generatedTransitionsPreserveSafetyRules() {
        var seeds: [UInt64] = [0, 1, 42, 0xDEAD_BEEF, UInt64.max]
        if let text = ProcessInfo.processInfo.environment["CONTROLKIT_TEST_SEED"],
            let supplied = UInt64(text)
        {
            seeds.append(supplied)
        }
        for seed in seeds {
            print("ControlKit production session seed: \(seed)")
            for scenario in 0..<64 {
                run(seed: seed &+ UInt64(scenario))
            }
        }
    }

    private func run(seed: UInt64) {
        var random = SessionRandom(seed)
        var machine = SessionMachine(queueLimit: 8, receiptLimit: 1_000)
        machine.markReady()
        var commands: [SessionCommand] = []
        for _ in 0..<100 {
            switch random.next() % 6 {
            case 0:
                let operations = SessionOperation.all
                let operation = operations[Int(random.next() % UInt64(operations.count))]
                let command = SessionCommand(
                    id: random.uuid(), fingerprint: "\(random.next())", operation: operation,
                    deadline: .now.advanced(by: .seconds(30)))
                _ = machine.admit(command, generation: machine.generation)
                commands.append(command)
            case 1:
                _ = machine.dispatch(now: .now)
            case 2:
                if let active = machine.active {
                    machine.finish(
                        id: active.id, generation: machine.generation,
                        succeeded: random.next() & 1 == 0,
                        effectsUncertain: random.next() % 16 == 0,
                        snapshot: active.operation == .inspect ? random.uuid() : nil)
                }
            case 3:
                if let command = commands.random(using: &random) {
                    machine.timeout(id: command.id)
                }
            case 4:
                if machine.state == .fenced, machine.beginRecovery() {
                    _ = machine.finishRecovery(oldRunnerRetired: random.next() & 1 == 0)
                }
            default:
                if let command = commands.random(using: &random) {
                    _ = machine.admit(command, generation: machine.generation)
                }
            }
            #expect(machine.queue.count <= 8)
            #expect(machine.receipts.count <= 1_000)
            #expect(machine.generation > 0)
        }
    }
}

private struct SessionRandom: RandomNumberGenerator {
    private var state: UInt64

    init(_ seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func uuid() -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<16 { bytes[index] = UInt8(truncatingIfNeeded: next()) }
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }
}

extension Array {
    fileprivate func random(using generator: inout SessionRandom) -> Element? {
        isEmpty ? nil : self[Int(generator.next() % UInt64(count))]
    }
}

extension SessionOperation {
    fileprivate static let all: [SessionOperation] = [
        .inspect, .find, .screenshot, .tap, .type, .setText, .swipe, .scroll, .wait,
        .systemAlertInspect, .systemAlertTap,
    ]
}
