/// Positive, non-wrapping helper identity within a session. Epoch/session checks remain mandatory.
package struct HelperGeneration: Equatable, Sendable {
    package let value: UInt64

    package init(_ value: UInt64) throws {
        guard value > 0 else { throw GenerationFailure.invalid }
        self.value = value
    }

    package func successor() throws -> Self {
        guard value < UInt64.max else { throw GenerationFailure.exhausted }
        return try Self(value + 1)
    }
}

package enum GenerationFailure: Error, Equatable {
    case invalid
    case exhausted
}
