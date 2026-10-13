import Foundation

package enum SessionState: String, Codable, Sendable {
    case starting, ready, executing, fenced, recovering, needsInspection, stopping, stopped
}

package enum SessionOperation: String, Codable, Sendable {
    case inspect = "ui.inspect"
    case find = "ui.find"
    case screenshot = "ui.screenshot"
    case tap = "ui.tap"
    case type = "ui.type"
    case setText = "ui.set_text"
    case swipe = "ui.swipe"
    case scroll = "ui.scroll"
    case wait = "ui.wait"
    case systemAlertInspect = "ui.system_alert.inspect"
    case systemAlertTap = "ui.system_alert.tap"

    package var isInspection: Bool { self == .inspect }
    package var isMutation: Bool {
        [.tap, .type, .setText, .swipe, .scroll, .systemAlertTap].contains(self)
    }
}

package enum ReceiptStatus: String, Codable, Sendable {
    case queued, dispatched, finished
    case notDispatched = "not_dispatched"
    case unknown
}

package struct SessionCommand: Sendable {
    package let id: UUID
    package let fingerprint: String
    package let operation: SessionOperation
    package let deadline: ContinuousClock.Instant

    package init(
        id: UUID, fingerprint: String, operation: SessionOperation,
        deadline: ContinuousClock.Instant
    ) {
        self.id = id
        self.fingerprint = fingerprint
        self.operation = operation
        self.deadline = deadline
    }
}

package struct SessionReceipt: Codable, Sendable {
    package let requestId: UUID
    package let fingerprint: String
    package let operation: SessionOperation
    package var status: ReceiptStatus
    package var errorCode: String?
    package var resultAvailable: Bool
}

package enum SessionAdmission: Equatable, Sendable {
    case accepted
    case duplicate(ReceiptStatus)
    case rejected(String)
}
