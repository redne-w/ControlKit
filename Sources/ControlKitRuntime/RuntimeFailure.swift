import Foundation

package struct RuntimeFailure: Error, Codable, Equatable, Sendable {
    package let code: String
    package let message: String

    package init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }
}

package func requireRuntime(_ condition: Bool, _ code: String, _ message: String) throws {
    guard condition else { throw RuntimeFailure(code, message) }
}

package func validateRuntimeText(_ text: String, limit: Int = 4_096) throws {
    try requireRuntime(
        !text.isEmpty && text.utf8.count <= limit
            && !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }
            ),
        "invalid_argument", "Invalid text or length.")
}
