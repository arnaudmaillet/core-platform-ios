import CoreModels
import Foundation
import Testing
@testable import Feed

private func entry(_ id: String, _ body: String) -> CommentEntry {
    CommentEntry(
        id: id,
        authorID: ProfileID("prof-1"),
        authorName: "Ava",
        authorHandle: "ava",
        body: body,
        createdAt: Date(timeIntervalSince1970: 1000)
    )
}

private func semanticEntries(_ count: Int) -> [CommentEntry] {
    (0..<count).map { entry("s\($0)", "This is a longer thought number \($0) worth reading.") }
}

struct SubtitleCommentBuilderTests {
    private let builder = SubtitleCommentBuilder()

    /// NO MINIMUM GATE. The zone used to hide below three cues, which is
    /// most posts — a page with a conversation showed no sign of it, and the
    /// "No comments yet" pill couldn't cover for it either, because the post
    /// is not empty. One comment is a stream now.
    @Test func anySingleCommentIsAStream() {
        #expect(builder.build(semanticEntries(1), postID: PostID("post-1")).count == 1)
        #expect(builder.build(semanticEntries(2), postID: PostID("post-1")).count == 2)
        #expect(builder.build([], postID: PostID("post-1")).isEmpty)
    }

    /// THE NO-BLANK FLOOR. A post whose comments are ALL reaction-shaped
    /// gets nothing from the band until it clears `minTickerCount`, so with
    /// the band off those comments have to land here — shape-blind — or they
    /// are invisible on a post that has them.
    @Test func reactionOnlyPostsStillFillTheZoneWhenTheBandIsOff() {
        let entries = [entry("a", "W"), entry("b", "🔥🔥"), entry("c", "so clean")]

        // Band off: every comment shows, whatever its shape.
        let withoutBand = builder.build(entries, postID: PostID("post-1"), tickerIsRendering: false)
        #expect(withoutBand.map(\.id) == ["a", "b", "c"])

        // Band on: it owns them, and the zone defers — one comment, one
        // surface. (Nothing is lost: they are visibly riding the band.)
        let withBand = builder.build(entries, postID: PostID("post-1"), tickerIsRendering: true)
        #expect(withBand.isEmpty)
    }

    /// The sparse seed, end to end: two comments, one reaction-shaped and one
    /// not, on a post whose band is below its gate. Both must be cues — this
    /// is the exact case that rendered a blank comment zone.
    @Test func theSparseSeedShowsBothOfItsComments() {
        let entries = [
            entry("c0", "Love this shot 🔥"),
            entry("c1", "Where was this taken?"),
        ]
        let cues = builder.build(entries, postID: PostID("post-0001"), tickerIsRendering: false)
        #expect(cues.map(\.id) == ["c0", "c1"])
    }

    /// The shape-blind fallback is a FLOOR, not a replacement: when semantic
    /// bodies exist they still win the zone outright, and short reactions
    /// beside them stay the band's.
    @Test func semanticBodiesStillWinTheZoneOverReactions() {
        let entries = semanticEntries(2) + [entry("react", "🔥🔥🔥")]
        let cues = builder.build(entries, postID: PostID("post-1"), tickerIsRendering: false)
        #expect(cues.map(\.id) == ["s0", "s1"])
    }

    /// The author's avatar rides from the comment entry into the cue, so the
    /// subtitle zone can draw it leading the text.
    @Test func carriesTheAuthorAvatarIntoTheCue() {
        let url = URL(string: "mock://avatar/5?w=128&h=128")!
        let entries = (0..<3).map { index in
            CommentEntry(
                id: "s\(index)", authorID: ProfileID("p\(index)"), authorName: "Ava",
                authorHandle: "ava", authorAvatarURL: url,
                body: "This is a longer thought number \(index) worth reading.",
                createdAt: Date(timeIntervalSince1970: 1000)
            )
        }
        let cues = builder.build(entries, postID: PostID("post-1"))
        #expect(!cues.isEmpty)
        #expect(cues.allSatisfy { $0.avatarURL == url })
    }

    /// One comment, one surface: anything the ticker admits never becomes a
    /// cue — including short slang the band takes via the word cap.
    @Test func tickerClaimedBodiesNeverBecomeCues() {
        let entries = semanticEntries(3) + [
            entry("emoji-run", "🔥🔥🔥"),
            entry("slang", "this goes hard"), // ≤3 words → the band's
            entry("short", "so clean"),
        ]
        let cues = builder.build(entries, postID: PostID("post-1"))
        let ids = Set(cues.map(\.id))
        #expect(cues.count == 3)
        #expect(ids.isDisjoint(with: ["emoji-run", "slang", "short"]))
    }

    /// The `isReactionShaped` precondition subtlety: a long emoji-bearing
    /// sentence is over the ticker's cap (so never claimed) and must land
    /// here — emoji presence alone doesn't make a reaction.
    @Test func longEmojiBearingSentencesQualify() {
        let entries = semanticEntries(3) + [
            entry("emotive", "this reminds me of home 🥹 honestly the best"),
        ]
        let cues = builder.build(entries, postID: PostID("post-1"))
        #expect(cues.contains { $0.id == "emotive" })
    }

    /// Word-count route: within the ticker's grapheme cap but past its word
    /// cap — the classic "sentence the band rejects" — is a cue.
    @Test func shortSentencesPastTheWordCapQualify() {
        let entries = semanticEntries(3) + [entry("phrase", "how is this so good")]
        let cues = builder.build(entries, postID: PostID("post-1"))
        #expect(cues.contains { $0.id == "phrase" })
    }

    /// Grapheme route: word-sparse but substantial bodies clear the floor.
    @Test func wordSparseButSubstantialBodiesQualify() {
        let entries = semanticEntries(3) + [
            entry("dense-words", "Unbelievable, extraordinary, breathtaking"),
        ]
        let cues = builder.build(entries, postID: PostID("post-1"))
        #expect(cues.contains { $0.id == "dense-words" })
    }

    @Test func newlinesCollapseIntoOneVisualBlock() {
        let entries = semanticEntries(3) + [
            entry("multiline", "the first line here\nthe second line here"),
            entry("tiny-multiline", "no\nway"), // collapses to a band-shaped body → rejected
        ]
        let cues = builder.build(entries, postID: PostID("post-1"))
        #expect(cues.first { $0.id == "multiline" }?.text == "the first line here the second line here")
        #expect(!cues.contains { $0.id == "tiny-multiline" })
    }

    @Test func deduplicatesCaseInsensitively() {
        let entries = semanticEntries(3) + [
            entry("dupe", "THIS IS A LONGER THOUGHT NUMBER 0 WORTH READING."),
        ]
        let cues = builder.build(entries, postID: PostID("post-1"))
        #expect(cues.count == 3)
        #expect(!cues.contains { $0.id == "dupe" })
    }

    @Test func capsCuesAtMaxItems() {
        let cues = builder.build(semanticEntries(SubtitleCommentBuilder.maxItems + 5), postID: PostID("post-1"))
        #expect(cues.count == SubtitleCommentBuilder.maxItems)
    }

    /// Unshuffled by design: cues keep delivery (recency) order, identically
    /// across builds — the band's seeded shuffle is a reaction-mixing trick
    /// that has no place under sentences.
    @Test func preservesDeliveryOrderDeterministically() {
        let entries = semanticEntries(5)
        let first = builder.build(entries, postID: PostID("post-1"))
        let again = SubtitleCommentBuilder().build(entries, postID: PostID("post-2"))
        #expect(first.map(\.id) == entries.map(\.id))
        #expect(first == again) // same cues regardless of post seed
    }
}
