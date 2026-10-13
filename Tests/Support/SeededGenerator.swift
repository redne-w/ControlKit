/// SplitMix64 with explicit wrapping arithmetic from the algorithm. Not cryptographic randomness.
/// Do not use stdlib random(in:) here: its sampling implementation is not a replay contract.
package struct SeededGenerator {
    private var state: UInt64

    package init(seed: UInt64) { state = seed }

    package mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58_476d_1ce4_e5b9
        value = (value ^ (value >> 27)) &* 0x94d0_49bb_1331_11eb
        return value ^ (value >> 31)
    }

    package mutating func index(upperBound: Int) -> Int {
        precondition(upperBound > 0)
        // Modulo bias is acceptable for choosing test events, not statistical measurement.
        return Int(next() % UInt64(upperBound))
    }
}
