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

    @Test func hidesZoneBelowMinimumGate() {
        let sparse = builder.build(semanticEntries(SubtitleCommentBuilder.minCueCount - 1), postID: PostID("post-1"))
        #expect(sparse.isEmpty)

        let dense = builder.build(semanticEntries(SubtitleCommentBuilder.minCueCount), postID: PostID("post-1"))
        #expect(dense.count == SubtitleCommentBuilder.minCueCount)
    }

    /// The author's avatar rides from the comment entry into the cue, so the
    /// subtitle zone can draw it leading the text.
    @Test func carriesTheAuthorAvatarIntoTheCue() {
        let url = URL(string: "mock://avatar/5?w=128&h=128")!
        let entries = (0..<SubtitleCommentBuilder.minCueCount).map { index in
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
