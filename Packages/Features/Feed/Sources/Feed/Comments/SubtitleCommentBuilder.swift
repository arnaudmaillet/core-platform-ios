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
    /// The comment author's avatar, shown leading the cue pill. Optional — a
    /// missing/unhydrated author renders the zone's placeholder circle.
    public let avatarURL: URL?

    public init(id: String, text: String, at: TimeInterval? = nil, avatarURL: URL? = nil) {
        self.id = id
        self.text = text
        self.at = at
        self.avatarURL = avatarURL
    }
}

/// Distills a post's comments into the subtitle zone's cue list — the snap
/// page's COMMENT STREAM. Pure and deterministic, like `CommentTickerBuilder`:
/// the same comments always produce the same cues.
///
/// THE ZONE IS NEVER BLANK ON A POST THAT HAS COMMENTS (product rule
/// 2026-08-08). Two things used to empty it, and both are gone:
///
///   • a minimum-cue gate (3) that hid the zone on sparse posts — which is
///     most of them; the "No comments yet" pill then couldn't cover for it
///     either, because the post is not empty. The result was a page that
///     had a conversation and showed no sign of it.
///   • the ticker's claim applied unconditionally: a reaction-shaped body
///     was excluded from the zone even when the band was BELOW its own
///     engagement gate and rendered nothing. Two short comments meant two
///     invisible comments.
///
/// Precedence therefore depends on whether the band is actually on screen.
/// When it renders, it keeps first claim and the zone takes the semantic
/// remainder — one comment, one surface, as before. When it does not, every
/// comment falls through to the zone, and a post whose comments are all
/// reaction-shaped still shows them (`cues(from:requiringSemanticShape:)`
/// runs a second, shape-blind pass rather than returning nothing).
///
/// Note the ticker's `isReactionShaped` cannot be reused as a bare
/// complement — it was designed under the band's 20-grapheme precondition,
/// and applied raw it would misclassify a long emoji-bearing sentence as a
/// reaction.
public struct SubtitleCommentBuilder: Sendable {
    /// Fewest words a body may carry and still read as a thought rather than
    /// a reaction — unless it clears `minCharacterCount` instead.
    public static let minWordCount = 4
    /// Grapheme floor admitting word-sparse but substantial bodies.
    public static let minCharacterCount = 25
    /// Cue cap; the zone wraps around, so it never needs more.
    public static let maxItems = 12

    public init() {}

    /// The cue list for `postID`.
    ///
    /// `tickerIsRendering` is the band's RESOLVED state — whether
    /// `CommentTickerBuilder` actually produced a queue for this post, not
    /// whether the bodies look reaction-shaped. Pass `false` and the zone
    /// speaks for every comment, because nothing else will.
    ///
    /// Empty only when `entries` is (or holds nothing but blank bodies), or
    /// when the band is carrying every comment already.
    public func build(
        _ entries: [CommentEntry],
        postID: PostID,
        tickerIsRendering: Bool = true
    ) -> [SubtitleCue] {
        let candidates = tickerIsRendering
            ? entries.filter { !Self.isClaimedByTicker(Self.flattened($0.body)) }
            : entries
        let semantic = cues(from: candidates, requiringSemanticShape: true)
        // The no-blank floor: a post with comments the band isn't showing
        // gets them here whatever their shape. "W" reads oddly in a cue
        // pill, and it reads far better than an empty zone on a post that
        // has a conversation.
        let resolved = semantic.isEmpty
            ? cues(from: candidates, requiringSemanticShape: false)
            : semantic
        // Delivery (recency) order, deliberately unshuffled: the band
        // shuffles to break up look-alike reactions; sentences read best in
        // the order people wrote them.
        return Array(resolved.prefix(Self.maxItems))
    }

    private func cues(from entries: [CommentEntry], requiringSemanticShape: Bool) -> [SubtitleCue] {
        var seenBodies = Set<String>()
        var cues: [SubtitleCue] = []
        for entry in entries {
            let body = Self.flattened(entry.body)
            guard !body.isEmpty,
                  !requiringSemanticShape || Self.isSemanticShaped(body),
                  seenBodies.insert(body.lowercased()).inserted else { continue }
            cues.append(SubtitleCue(id: entry.id, text: body, avatarURL: entry.authorAvatarURL))
        }
        return cues
    }

    /// Subtitles render one visual block, so embedded newlines collapse
    /// instead of disqualifying (the band rejects them because a conveyor
    /// bubble is strictly single-line).
    static func flattened(_ body: String) -> String {
        body.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
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
