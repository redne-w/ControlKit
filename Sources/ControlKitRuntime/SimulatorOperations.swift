import Foundation

package struct SimulatorDevice: Codable, Sendable {
    package let udid: UUID
    package let name: String
    package let state: String
    package let isAvailable: Bool
    package let dataPath: String
}

package final class SimulatorOperations {
    let tools: AppleTools
    package let state: PrivateDirectory
    package let leases: PrivateDirectory

    package init(tools: AppleTools) throws {
        self.tools = tools
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .resolvingSymlinksInPath()
        state = try PrivateDirectory(base.appendingPathComponent("ControlKit-runtime"))
        leases = try PrivateDirectory(base.appendingPathComponent("ControlKit-device-leases-v3"))
    }

    package func list() throws -> [SimulatorDevice] {
        try list(budget: OperationBudget(milliseconds: 30_000))
    }

    package func list(budget: OperationBudget) throws -> [SimulatorDevice] {
        struct Inventory: Decodable { let devices: [String: [SimulatorDevice]] }
        let data = try tools.run(
            ["simctl", "list", "devices", "available", "--json"], budget: budget)
        guard let inventory = try? JSONDecoder().decode(Inventory.self, from: data) else {
            throw RuntimeFailure("tool_output", "Unexpected simulator inventory.")
        }
        let devices = inventory.devices.values.flatMap { $0 }
        try requireRuntime(
            inventory.devices.count <= 64 && devices.count <= 512,
            "resource_limit", "Simulator inventory exceeds supported bounds.")
        return devices.sorted { $0.udid.uuidString < $1.udid.uuidString }
    }

    package func device(
        _ id: UUID, budget: OperationBudget = OperationBudget(milliseconds: 30_000)
    ) throws
        -> SimulatorDevice
    {
        let matches = try list(budget: budget).filter { $0.udid == id && $0.isAvailable }
        try requireRuntime(
            matches.count == 1, "device_missing", "Choose one available simulator UDID.")
        return matches[0]
    }

    package func boot(_ id: UUID, budget suppliedBudget: OperationBudget? = nil) throws {
        let budget = suppliedBudget ?? OperationBudget(milliseconds: 120_000)
        let claim = try DeviceClaim(directory: leases, device: id, operation: "sim.boot")
        let current = try device(id, budget: budget)
        if current.state == "Booted" {
            try claim.complete()
            return
        }
        try requireRuntime(
            current.state == "Shutdown", "device_busy", "Simulator is transitioning.")
        try claim.begin()
        _ = try tools.run(["simctl", "boot", id.uuidString], budget: budget)
        _ = try tools.run(
            ["simctl", "bootstatus", id.uuidString, "-b"], milliseconds: 120_000, budget: budget)
        try requireRuntime(
            try device(id, budget: budget).state == "Booted",
            "device_busy", "Boot was not confirmed.")
        try claim.complete()
    }

    package func shutdown(_ id: UUID, budget suppliedBudget: OperationBudget? = nil) throws {
        let budget = suppliedBudget ?? OperationBudget(milliseconds: 120_000)
        let claim = try DeviceClaim(directory: leases, device: id, operation: "sim.shutdown")
        let current = try device(id, budget: budget)
        if current.state == "Shutdown" {
            try claim.complete()
            return
        }
        try requireRuntime(current.state == "Booted", "device_busy", "Simulator is transitioning.")
        try claim.begin()
        _ = try tools.run(
            ["simctl", "shutdown", id.uuidString], milliseconds: 120_000, budget: budget)
        try requireRuntime(
            try device(id, budget: budget).state == "Shutdown",
            "device_busy", "Shutdown was not confirmed.")
        try claim.complete()
    }

    package func create(
        name: String, runtime: String, deviceType: String,
        budget suppliedBudget: OperationBudget? = nil
    ) throws -> UUID {
        let budget = suppliedBudget ?? OperationBudget(milliseconds: 30_000)
        try validateRuntimeText(name, limit: 128)
        try validateRuntimeText(runtime, limit: 128)
        try validateRuntimeText(deviceType, limit: 128)
        try requireRuntime(
            runtime.hasPrefix("com.apple.CoreSimulator.SimRuntime.")
                && deviceType.hasPrefix("com.apple.CoreSimulator.SimDeviceType."),
            "invalid_argument", "Use explicit runtime and device-type identifiers.")
        let claim = try DeviceClaim(directory: leases, device: nil, operation: "sim.create")
        try claim.begin()
        let data = try tools.run(["simctl", "create", name, deviceType, runtime], budget: budget)
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard let id = UUID(uuidString: value) else {
            throw RuntimeFailure(
                "outcome_unknown", "Device creation returned an unrecognized identity.")
        }
        _ = try device(id, budget: budget)
        try claim.complete()
        return id
    }
}
