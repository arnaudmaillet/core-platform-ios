import CoreModels
import Foundation

/// One bubble of the snap feed's comment ticker: a short comment reduced to
/// exactly what the conveyor renders.
public struct TickerCommentModel: Equatable, Sendable, Identifiable {
    public let id: String
    public let text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

/// Distills a post's comments into the ticker's wrap-around queue. Pure and
/// deterministic: the same comments for the same post always produce the same
/// queue, so re-activating a page resumes an identical stream.
public struct CommentTickerBuilder: Sendable {
    /// Longest body (in characters, post-trim) that qualifies as "short".
    public static let maxCharacterCount = 48
    /// The engagement gate: fewer qualifying comments than this returns an
    /// empty queue and the band stays hidden — three lanes fed by a sparse
    /// loop read as a glitch, not a stream.
    public static let minTickerCount = 6
    /// Queue cap; the conveyor wraps around, so it never needs more.
    public static let maxItems = 30

    public init() {}

    /// The ticker queue for `postID`, or `[]` when the post doesn't clear the
    /// minimum-engagement gate.
    public func build(_ entries: [CommentEntry], postID: PostID) -> [TickerCommentModel] {
        var seenBodies = Set<String>()
        var qualifying: [TickerCommentModel] = []
        for entry in entries {
            let body = entry.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty,
                  body.count <= Self.maxCharacterCount,
                  !body.contains(where: \.isNewline),
                  seenBodies.insert(body.lowercased()).inserted else { continue }
            qualifying.append(TickerCommentModel(id: entry.id, text: body))
        }
        guard qualifying.count >= Self.minTickerCount else { return [] }

        // Shuffle so recency order doesn't cluster similar comments, but
        // seeded per post so the mix is stable across re-activations.
        var generator = SplitMix64(seed: Self.fnv1a(postID.rawValue))
        qualifying.shuffle(using: &generator)
        return Array(qualifying.prefix(Self.maxItems))
    }

    /// Stable across launches — `Hasher` is per-process seeded, and the
    /// shuffle must not reorder between runs.
    static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}

/// Minimal seeded RNG backing the deterministic shuffle.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}
