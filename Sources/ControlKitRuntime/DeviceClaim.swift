import Foundation

/// A crash leaves a fence, not permission for another invocation to repeat an uncertain operation.
/// Supervisor recovery/adoption is milestone 7; this layer never guesses from a stale PID.
package final class DeviceClaim {
    let directory: PrivateDirectory
    private let lock: FileLock
    private let record: String
    private let operation: String
    package let launchID = UUID()

    package init(directory: PrivateDirectory, device: UUID?, operation: String) throws {
        self.directory = directory
        self.operation = operation
        let key = device?.uuidString ?? "create"
        record = "\(key).json"
        _ = try directory.entries()
        lock = try FileLock(directory: directory, name: "\(key).lock")
        try requireRuntime(
            try !directory.exists(record), "retirement_unconfirmed",
            "An earlier operation needs recovery; its ownership record is retained.")
    }

    package func begin() throws {
        let data = try JSONSerialization.data(
            withJSONObject: ["launchId": launchID.uuidString, "operation": operation])
        try directory.write(record, data: data)
    }

    package func complete() throws {
        if try directory.exists(record) { try directory.remove(record) }
    }
}
