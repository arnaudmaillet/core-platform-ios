import CoreModels
import DesignSystem
import Foundation

/// One bubble of the snap feed's comment ticker: a short comment reduced to
/// exactly what the conveyor renders.
public struct TickerCommentModel: Equatable, Sendable, Identifiable {
    public let id: String
    public let text: String
    /// The comment author's avatar, shown leading the bubble over their
    /// initials. Optional — an author with no picture (or one not loaded yet,
    /// or failed) shows the initials alone (#1308).
    public let avatarURL: URL?
    /// The author's initials: the bubble's disc is never an empty grey plate.
    public let monogram: String

    public init(id: String, text: String, avatarURL: URL? = nil, monogram: String = "?") {
        self.id = id
        self.text = text
        self.avatarURL = avatarURL
        self.monogram = monogram
    }
}

/// Distills a post's comments into the band's POOL of reactions. Pure and
/// deterministic: the same comments always produce the same pool, in the
/// order they came — so a page that lands later only ADDS to it, and the
/// band keeps running (#2005). The band's tape shuffles each cycle
/// (`ReactionTape`).
///
/// The band is a micro-reaction dump, not a comment stream: it exists to
/// offload "GG 🔥🔥"-class reactions from the primary comment sheet. The
/// filter is shaped accordingly — dense emoji runs and short slang tokens
/// ride; semantic phrases stay in the sheet.
public struct CommentTickerBuilder: Sendable {
    /// Longest body (grapheme clusters, post-trim) that can ride the band.
    public static let maxCharacterCount = 20
    /// Emoji-free bodies additionally may carry at most this many words:
    /// within the character cap, "this goes hard" is a reaction, while
    /// "how is this so good" is a sentence that belongs in the sheet.
    public static let maxWordCount = 3
    /// The engagement gate: fewer qualifying comments than this returns an
    /// empty queue and the band stays hidden — three lanes fed by a sparse
    /// loop read as a glitch, not a stream.
    public static let minTickerCount = 6
    /// One cycle of the band's tape (`ReactionTape.cycleSize`). It capped
    /// the whole queue until #2005, when the conveyor looped on it.
    public static let maxItems = 30
    /// The pool's cap: a cycle per page, the first and the band's extra ones
    /// (`FeedViewModel.maxExtraReactionPages`).
    public static let maxPoolItems = maxItems * 6

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
                  Self.isReactionShaped(body),
                  seenBodies.insert(body.lowercased()).inserted else { continue }
            qualifying.append(TickerCommentModel(
                id: entry.id, text: body, avatarURL: entry.authorAvatarURL,
                monogram: MonogramAvatarView.monogram(name: entry.authorName, handle: entry.authorHandle)
            ))
        }
        guard qualifying.count >= Self.minTickerCount else { return [] }
        // ⚠️ IN THE ORDER THEY CAME, NOT SHUFFLED (#2005): a later page then
        // only appends, and the band merges it without a restart. The mix —
        // recency order would cluster similar comments — is the tape's, a
        // new shuffle per cycle.
        return Array(qualifying.prefix(Self.maxPoolItems))
    }

    /// Reaction shape: any emoji-bearing body qualifies outright (dense emoji
    /// runs are the band's favorite payload — the character cap alone bounds
    /// them), while plain text must also clear the word cap so short slang
    /// passes and semantic phrases don't.
    static func isReactionShaped(_ body: String) -> Bool {
        let hasEmoji = body.unicodeScalars.contains { scalar in
            // `isEmojiPresentation` covers default-emoji scalars (🔥 😭 🐐);
            // U+FE0F catches text-default scalars forced into emoji form
            // (❤️). Plain `isEmoji` would be wrong here — it is true for
            // digits and '#'.
            scalar.properties.isEmojiPresentation || scalar.value == 0xFE0F
        }
        if hasEmoji { return true }
        return body.split(whereSeparator: \.isWhitespace).count <= Self.maxWordCount
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
