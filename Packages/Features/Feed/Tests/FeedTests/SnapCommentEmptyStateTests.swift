import CoreModels
import DesignSystem
import Testing
import UIKit
@testable import Feed

/// The comments empty state's visibility contract: the "No comments yet"
/// pill renders exactly when a media post's stream is LOADED with a zero
/// count. The COUNT is the whole condition — never on the pre-load `.empty`
/// default (no flash while a fetch is in flight), never on a text-only page
/// (the empty shell), and never on a post that HAS comments, whatever the
/// surfaces above choose to do with them.
@MainActor
struct SnapCommentEmptyStateTests {
    private func makeChrome(mediaURL: URL? = URL(string: "mock://media/9")) -> SnapChromeView {
        let chrome = SnapChromeView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        chrome.configure(with: FeedItemDisplayModel(
            id: PostID("post-0009"),
            authorID: ProfileID("profile-1"),
            authorName: "Ana",
            metaText: "@ana · 3m",
            avatarURL: nil,
            caption: "caption",
            mediaURL: mediaURL,
            mediaKind: .image,
            thumbnailURL: nil,
            audioText: nil
        ))
        return chrome
    }

    private func emptyState(in chrome: SnapChromeView) throws -> SnapCommentEmptyStateView {
        try #require(chrome.subviews.compactMap { $0 as? SnapCommentEmptyStateView }.first)
    }

    @Test func promptRendersOnlyOnKnownZero() throws {
        let chrome = makeChrome()
        let prompt = try emptyState(in: chrome)

        // Configured but unloaded (the flight replica's and the dequeue
        // pull's state): blank zone, no prompt — nothing may flash while a
        // fetch is in flight.
        #expect(prompt.isHidden == true)
        chrome.updateCommentStreams(.empty)
        #expect(prompt.isHidden == true)

        // A loaded zero-comment stream admits the pill…
        chrome.updateCommentStreams(FeedViewModel.CommentStreams(
            reactions: [], subtitles: [], commentCount: 0
        ))
        #expect(prompt.isHidden == false)
        #expect(prompt.accessibilityLabel == SnapCommentEmptyStateView.promptText)

        // …and comments arriving (e.g. the viewer composed one) hand the
        // zone back to the band.
        chrome.updateCommentStreams(FeedViewModel.CommentStreams(
            reactions: (0..<8).map { TickerCommentModel(id: "c\($0)", text: "fire \($0)") },
            subtitles: [],
            commentCount: 8
        ))
        #expect(prompt.isHidden == true)
    }

    /// A post that HAS comments never gets the pill — not even when both
    /// surfaces' engagement gates drop them and the zone renders blank. The
    /// stream is the only thing allowed to speak for such a post; a count
    /// standing in for it ("2 comments") was tried in this slot and removed.
    @Test func postsWithCommentsNeverShowThePrompt() throws {
        let chrome = makeChrome()
        let prompt = try emptyState(in: chrome)

        // Gated-but-nonzero: both surfaces silent, and still no pill.
        chrome.updateCommentStreams(FeedViewModel.CommentStreams(
            reactions: [], subtitles: [], commentCount: 2
        ))
        #expect(prompt.isHidden == true)

        // A single comment is already "has comments".
        chrome.updateCommentStreams(FeedViewModel.CommentStreams(
            reactions: [], subtitles: [], commentCount: 1
        ))
        #expect(prompt.isHidden == true)

        // And a speaking surface (cues, no band-worthy reactions) likewise.
        chrome.updateCommentStreams(FeedViewModel.CommentStreams(
            reactions: [],
            subtitles: (0..<3).map {
                SubtitleCue(id: "s\($0)", text: "A whole sentence worth reading \($0).")
            },
            commentCount: 3
        ))
        #expect(prompt.isHidden == true)
    }

    /// The copy is fixed — the pill only ever speaks for the zero case, so
    /// there is exactly one string it can say.
    @Test func promptCopyIsTheZeroStateOnly() throws {
        let chrome = makeChrome()
        let prompt = try emptyState(in: chrome)
        chrome.updateCommentStreams(FeedViewModel.CommentStreams(
            reactions: [], subtitles: [], commentCount: 0
        ))
        #expect(prompt.accessibilityLabel == "No comments yet")
        #expect(SnapCommentEmptyStateView.promptText == "No comments yet")
    }

    /// The pill retires the instant the post stops being empty — the viewer
    /// composing the first comment is the live path through this.
    @Test func theFirstCommentRetiresThePrompt() throws {
        let chrome = makeChrome()
        let prompt = try emptyState(in: chrome)
        chrome.updateCommentStreams(FeedViewModel.CommentStreams(
            reactions: [], subtitles: [], commentCount: 0
        ))
        #expect(prompt.isHidden == false)
        chrome.updateCommentStreams(FeedViewModel.CommentStreams(
            reactions: [], subtitles: [], commentCount: 1
        ))
        #expect(prompt.isHidden == true)
    }

    @Test func textOnlyPostsRefuseThePrompt() throws {
        let chrome = makeChrome(mediaURL: nil)
        let prompt = try emptyState(in: chrome)
        // Text-only pages are an empty shell; even a loaded zero stream
        // must bounce off the same `hasMedia` wall as the other surfaces.
        chrome.updateCommentStreams(FeedViewModel.CommentStreams(
            reactions: [], subtitles: [], commentCount: 0
        ))
        #expect(prompt.isHidden == true)
    }

    /// Alpha is shared between the pill's entrance and the comments
    /// engagement's chrome fade, and this is the one surface that writes it
    /// itself. Cached streams re-emit on every page activation, so a
    /// re-emission arriving while the comments layout is open must settle at
    /// the faded alpha instead of animating the pill back over it.
    @Test func aStreamArrivingMidEngagementStaysFaded() throws {
        let chrome = makeChrome()
        let prompt = try emptyState(in: chrome)
        chrome.setCommentsEngaged(true)
        chrome.updateCommentStreams(FeedViewModel.CommentStreams(
            reactions: [], subtitles: [], commentCount: 0
        ))
        #expect(prompt.alpha == 0)

        // …and the pull-down brings it back with everything else.
        chrome.setCommentsEngaged(false)
        #expect(prompt.alpha == 1)
        #expect(prompt.isHidden == false)
    }

    /// THE ROW SHAPE. The empty state stands in a comment row's place, so it
    /// is built like one: `[avatar slot] [gap] [content]`. It used to be a
    /// single pill with the glyph inside it as a text attachment, which put
    /// the WORDS on the leading axis where every comment row puts its
    /// AVATAR — the placeholder sat half a slot left of the thing it stands
    /// in for.
    @Test func thePromptIsBuiltLikeACommentRow() throws {
        let chrome = makeChrome()
        chrome.setFixedInsets(UIEdgeInsets(top: 103, left: 0, bottom: 34, right: 0))
        let prompt = try emptyState(in: chrome)
        chrome.updateCommentStreams(FeedViewModel.CommentStreams(
            reactions: [], subtitles: [], commentCount: 0
        ))
        chrome.layoutIfNeeded()

        let slot = try #require(prompt.subviews.first { $0 !== prompt.subviews.compactMap { $0 as? UILabel }.first })
        let pill = try #require(prompt.subviews.compactMap { $0 as? SubtitlePillLabel }.first)

        // The glyph's seat IS the avatar's: same diameter, same circle, on
        // the row's own leading edge — one constant, so the two can't drift.
        #expect(slot.frame.width == SnapSubtitleView.avatarDiameter)
        #expect(slot.frame.height == SnapSubtitleView.avatarDiameter)
        #expect(slot.frame.minX == 0)
        #expect(slot.layer.cornerRadius == SnapSubtitleView.avatarDiameter / 2)
        // Content slot: the cue's gap off the avatar's trailing edge.
        #expect(abs(pill.frame.minX - (slot.frame.maxX + Spacing.sm)) < 0.5)
        // Both centred on the row, as the cue's avatar and pill are.
        #expect(abs(pill.frame.midY - slot.frame.midY) < 0.5)
    }

    /// The zone and the empty state occupy ONE leading column: whichever of
    /// them is showing, its avatar-slot circle starts at the same x. This is
    /// the alignment the row shape exists to get right — a chrome-level
    /// assertion, because that is where the two are placed.
    @Test func thePromptAndACueShareTheSameLeadingColumn() throws {
        let chrome = makeChrome()
        chrome.setFixedInsets(UIEdgeInsets(top: 103, left: 0, bottom: 34, right: 0))
        let prompt = try emptyState(in: chrome)
        let zone = try #require(chrome.subviews.compactMap { $0 as? SnapSubtitleView }.first)

        chrome.updateCommentStreams(FeedViewModel.CommentStreams(
            reactions: [], subtitles: [], commentCount: 0
        ))
        chrome.layoutIfNeeded()
        let promptColumn = prompt.frame.minX

        chrome.updateCommentStreams(FeedViewModel.CommentStreams(
            reactions: [],
            subtitles: [SubtitleCue(id: "s0", text: "A whole sentence worth reading here.")],
            commentCount: 1
        ))
        chrome.layoutIfNeeded()

        #expect(zone.frame.minX == promptColumn)
    }

    // MARK: - The label's dwell

    private func pill(in prompt: SnapCommentEmptyStateView) throws -> SubtitlePillLabel {
        try #require(prompt.subviews.compactMap { $0 as? SubtitlePillLabel }.first)
    }

    /// The words hold at full strength for a reading beat, then settle onto
    /// a parked resting opacity — MUTED, never gone. Ending ON the model
    /// value is what stops backgrounding, which strips CA animations, from
    /// snapping them back to full.
    @Test func theLabelDwellsThenSettlesToMuted() throws {
        let chrome = makeChrome()
        let prompt = try emptyState(in: chrome)
        let label = try pill(in: prompt)

        chrome.updateCommentStreams(FeedViewModel.CommentStreams(
            reactions: [], subtitles: [], commentCount: 0
        ))
        // Not yet on screen: no clock. A dwell armed at the dequeue pull
        // would burn off-screen and the words would be gone on arrival.
        #expect(label.layer.animation(forKey: "empty-state-label-dwell") == nil)
        #expect(label.layer.opacity == 1)

        chrome.setSubtitlesActive(true)
        let dwell = try #require(label.layer.animation(forKey: "empty-state-label-dwell") as? CAKeyframeAnimation)
        let resting = Double(SnapCommentEmptyStateView.labelRestingOpacity)
        #expect((dwell.values as? [NSNumber])?.map(\.doubleValue) == [1, 1, resting])
        #expect(dwell.fillMode == .forwards)
        #expect(dwell.isRemovedOnCompletion == false)
        #expect(dwell.duration == SnapCommentEmptyStateView.labelDwell + SnapCommentEmptyStateView.labelFadeDuration)
        // Holds at full opacity for the whole reading beat, then ramps.
        let holdUntil = try #require(dwell.keyTimes?[1]).doubleValue
        #expect(abs(holdUntil * dwell.duration - SnapCommentEmptyStateView.labelDwell) < 0.001)
        // Parked at the resting value, so the fill-forwards end and the
        // model agree.
        #expect(label.layer.opacity == SnapCommentEmptyStateView.labelRestingOpacity)
        // Muted, not gone: still readable, no longer prominent.
        #expect(SnapCommentEmptyStateView.labelRestingOpacity > 0.1)
        #expect(SnapCommentEmptyStateView.labelRestingOpacity < 1)
    }

    /// Leaving the screen restores the words: a page revisited, or the
    /// scaffold recycled onto another zero-comment post, reads them again.
    @Test func leavingTheScreenRewindsTheDwell() throws {
        let chrome = makeChrome()
        let prompt = try emptyState(in: chrome)
        let label = try pill(in: prompt)
        chrome.updateCommentStreams(FeedViewModel.CommentStreams(
            reactions: [], subtitles: [], commentCount: 0
        ))

        chrome.setSubtitlesActive(true)
        #expect(label.layer.animation(forKey: "empty-state-label-dwell") != nil)

        chrome.setSubtitlesActive(false)
        #expect(label.layer.animation(forKey: "empty-state-label-dwell") == nil)
        #expect(label.layer.opacity == 1)

        chrome.setSubtitlesActive(true)
        #expect(label.layer.animation(forKey: "empty-state-label-dwell") != nil)

        // Reuse clears the seam too, so the next post's words are not
        // already spent when its stream lands.
        chrome.reset()
        #expect(label.layer.opacity == 1)
    }

    /// CLOSING THE COMMENTS REWINDS THE BEAT. Coming back out of the
    /// engagement is a return to the page, and the page introduces itself
    /// again — the alternative is meeting a pre-muted label at the exact
    /// moment the viewer last expressed interest in this post's comments.
    @Test func closingTheCommentsReadsTheWordsAgain() throws {
        let chrome = makeChrome()
        let prompt = try emptyState(in: chrome)
        let label = try pill(in: prompt)
        chrome.updateCommentStreams(FeedViewModel.CommentStreams(
            reactions: [], subtitles: [], commentCount: 0
        ))
        chrome.setSubtitlesActive(true)
        let first = try #require(label.layer.animation(forKey: "empty-state-label-dwell"))

        // Engaged: the chrome fades out, beat included.
        chrome.setCommentsEngaged(true)
        #expect(prompt.alpha == 0)

        // …and back. A NEW animation, from full strength.
        chrome.setCommentsEngaged(false)
        #expect(prompt.alpha == 1)
        let second = try #require(label.layer.animation(forKey: "empty-state-label-dwell"))
        #expect(second !== first)
        #expect(label.layer.opacity == SnapCommentEmptyStateView.labelRestingOpacity)
    }

    /// The interactive pull-down shares the seam: it lands on the same
    /// progress == 1 the animated close does. A drag that springs BACK never
    /// reaches 1, so it must not rewind anything.
    @Test func onlyAFullReturnToRestRewindsTheBeat() throws {
        let chrome = makeChrome()
        let prompt = try emptyState(in: chrome)
        let label = try pill(in: prompt)
        chrome.updateCommentStreams(FeedViewModel.CommentStreams(
            reactions: [], subtitles: [], commentCount: 0
        ))
        chrome.setSubtitlesActive(true)

        chrome.setCommentsEngagedProgress(0)
        chrome.setCommentsEngagedProgress(0.4) // dragging out…
        let midDrag = label.layer.animation(forKey: "empty-state-label-dwell")
        chrome.setCommentsEngagedProgress(0) // …and it springs back
        #expect(label.layer.animation(forKey: "empty-state-label-dwell") === midDrag)

        // Committing to the end is what rewinds it.
        chrome.setCommentsEngagedProgress(0.7)
        chrome.setCommentsEngagedProgress(1)
        let rewound = try #require(label.layer.animation(forKey: "empty-state-label-dwell"))
        #expect(rewound !== midDrag)

        // Already at rest: nothing re-arms on a repeated write.
        chrome.setCommentsEngagedProgress(1)
        #expect(label.layer.animation(forKey: "empty-state-label-dwell") === rewound)
    }

    /// The row's geometry survives the settle untouched, so the whole slot —
    /// glyph, gap and words alike — is one tap into the comments at every
    /// point in the animation.
    @Test func theRowStaysTappableAfterTheLabelSettles() throws {
        let chrome = makeChrome()
        chrome.setFixedInsets(UIEdgeInsets(top: 103, left: 0, bottom: 34, right: 0))
        let prompt = try emptyState(in: chrome)
        let label = try pill(in: prompt)
        var taps = 0
        chrome.onCommentsTapped = { taps += 1 }

        chrome.updateCommentStreams(FeedViewModel.CommentStreams(
            reactions: [], subtitles: [], commentCount: 0
        ))
        chrome.layoutIfNeeded()
        let rowBefore = prompt.frame
        let textColumn = label.frame

        chrome.setSubtitlesActive(true)
        chrome.layoutIfNeeded()

        // The row did not move or shrink…
        #expect(prompt.frame == rowBefore)
        #expect(label.frame == textColumn)
        #expect(label.frame.width > 0)
        // …and a touch in the now-invisible text column still lands inside
        // the row, which is the chrome's declared interaction root.
        // …and a touch in the text column still resolves through the
        // arbitration. The ROW answers for that column whatever the label's
        // opacity, because a `UILabel` is not interactive to begin with —
        // which is why the resting value can be tuned freely (or taken to 0)
        // without the tap target moving with it. Asserted through the real
        // predicate: a hit on an interaction root ITSELF, not a descendant.
        let inTextColumn = CGPoint(x: label.frame.midX, y: label.frame.midY)
        let hit = try #require(prompt.hitTest(inTextColumn, with: nil))
        #expect(label.isUserInteractionEnabled == false)
        #expect(hit === prompt)
        #expect(chrome.interactionRoots.contains(prompt))
        #expect(SnapFeedCell.isInteractiveTouch(
            hit, interactiveRoots: chrome.interactionRoots, stopAt: chrome
        ))
        // The glyph half of the row answers the same way.
        let onGlyph = try #require(prompt.hitTest(CGPoint(x: 6, y: prompt.bounds.midY), with: nil))
        #expect(SnapFeedCell.isInteractiveTouch(
            onGlyph, interactiveRoots: chrome.interactionRoots, stopAt: chrome
        ))

        prompt.onTap?()
        #expect(taps == 1)
    }

    @Test func reuseResetHidesThePrompt() throws {
        let chrome = makeChrome()
        let prompt = try emptyState(in: chrome)
        chrome.updateCommentStreams(FeedViewModel.CommentStreams(
            reactions: [], subtitles: [], commentCount: 0
        ))
        #expect(prompt.isHidden == false)
        chrome.reset()
        #expect(prompt.isHidden == true)
    }

    /// The pill occupies the band's slot as an overlay: directly above the
    /// caption on its leading text axis, constraining nothing around it —
    /// the caption's frame is identical with and without it.
    @Test func promptSitsInTheBandSlotWithoutMovingTheStack() throws {
        let chrome = makeChrome()
        chrome.setFixedInsets(UIEdgeInsets(top: 103, left: 0, bottom: 34, right: 0))
        chrome.layoutIfNeeded()
        let caption = try #require(
            chrome.subviews.compactMap { $0 as? UILabel }.first { $0.attributedText?.string == "caption" }
        )
        let captionFrameBefore = caption.frame

        let prompt = try emptyState(in: chrome)
        chrome.updateCommentStreams(FeedViewModel.CommentStreams(
            reactions: [], subtitles: [], commentCount: 0
        ))
        chrome.layoutIfNeeded()
        #expect(caption.frame == captionFrameBefore)
        // md — the harmonized inter-container seam (it stands in the
        // band's seat, so it keeps the band's gap against the caption).
        //
        // ⚠️ Compared with a tolerance, not `==`. Both sides are laid out on a
        // fractional scale (754.666… at 3x), and the two arrive by different
        // arithmetic — exact equality held on CI's device and was off by one
        // ulp on an iPhone 17 Pro, which is a rounding artefact rather than a
        // layout error. Half a point is far below anything visible and far
        // above the error being tolerated.
        #expect(abs(prompt.frame.maxY - (captionFrameBefore.minY - Spacing.md)) < 0.5)
        #expect(prompt.frame.minX == caption.frame.minX)
        #expect(prompt.frame.height > 0)
    }
}
