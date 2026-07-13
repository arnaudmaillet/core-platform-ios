import CoreModels
import Foundation

/// One subtitle cue: a semantic comment reduced to what the subtitle zone
/// renders.
public struct SubtitleCue: Equatable, Sendable, Identifiable {
    public let id: String
    public let text: String
    /// Playback-timeline anchor, in seconds from the media's start. Always
    /// nil today — the comment API carries no timestamp payloads yet; nil
    /// cues are paced evenly from page activation. When the payload lands,
    /// populate this and scheduling moves onto the player clock
    /// (`SnapSubtitleView` keeps rendering "the current cue" either way).
    public let at: TimeInterval?

    public init(id: String, text: String, at: TimeInterval? = nil) {
        self.id = id
        self.text = text
        self.at = at
    }
}

/// Distills a post's comments into the subtitle zone's cue list — the
/// conveyor's complement. Pure and deterministic, like `CommentTickerBuilder`:
/// the same comments always produce the same cues.
///
/// The zone is for longer, thought-out comments; micro-reactions belong to
/// the band. Precedence is explicit: any body the ticker would admit is never
/// a cue, so one comment rides exactly one surface. Note the ticker's
/// `isReactionShaped` cannot be reused as a bare complement — it was designed
/// under the band's 20-grapheme precondition, and applied raw it would
/// misclassify a long emoji-bearing sentence as a reaction.
public struct SubtitleCommentBuilder: Sendable {
    /// Fewest words a body may carry and still read as a thought rather than
    /// a reaction — unless it clears `minCharacterCount` instead.
    public static let minWordCount = 4
    /// Grapheme floor admitting word-sparse but substantial bodies.
    public static let minCharacterCount = 25
    /// The engagement gate, same reasoning as the band's `minTickerCount`:
    /// one lonely sentence looping every few seconds reads as a glitch, not
    /// a stream. Below it the zone stays hidden.
    public static let minCueCount = 3
    /// Cue cap; the zone wraps around, so it never needs more.
    public static let maxItems = 12

    public init() {}

    /// The cue list for `postID`, or `[]` when the post doesn't clear the
    /// minimum-engagement gate.
    public func build(_ entries: [CommentEntry], postID: PostID) -> [SubtitleCue] {
        var seenBodies = Set<String>()
        var cues: [SubtitleCue] = []
        for entry in entries {
            // Subtitles render one visual block, so embedded newlines
            // collapse instead of disqualifying (the band rejects them
            // because a conveyor bubble is strictly single-line).
            let body = entry.body
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !body.isEmpty,
                  !Self.isClaimedByTicker(body),
                  Self.isSemanticShaped(body),
                  seenBodies.insert(body.lowercased()).inserted else { continue }
            cues.append(SubtitleCue(id: entry.id, text: body))
        }
        guard cues.count >= Self.minCueCount else { return [] }
        // Delivery (recency) order, deliberately unshuffled: the band
        // shuffles to break up look-alike reactions; sentences read best in
        // the order people wrote them.
        return Array(cues.prefix(Self.maxItems))
    }

    /// The ticker's admission, verbatim: within its grapheme cap and
    /// reaction-shaped. Runs first so the two surfaces partition cleanly.
    static func isClaimedByTicker(_ body: String) -> Bool {
        body.count <= CommentTickerBuilder.maxCharacterCount
            && CommentTickerBuilder.isReactionShaped(body)
    }

    /// Semantic shape: enough words to be a thought, or enough substance to
    /// clear the grapheme floor. Emoji *presence* never disqualifies — only
    /// the ticker's claim (which owns emoji-dominant shorts) does.
    static func isSemanticShaped(_ body: String) -> Bool {
        body.split(whereSeparator: \.isWhitespace).count >= Self.minWordCount
            || body.count >= Self.minCharacterCount
    }
}
