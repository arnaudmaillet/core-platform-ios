import CoreModels
import DesignSystem
import Testing
import UIKit
@testable import Feed

/// The comment zone's FLOOR contract: the pill renders whenever a media
/// post's live surfaces (ticker band, subtitle zone) render nothing on a
/// LOADED stream — never on the pre-load `.empty` default (no flash while a
/// fetch is in flight), never on a text-only page (the empty shell), and
/// never alongside a surface that is already speaking. Its copy tells the
/// two silences apart: "No comments yet" at zero, the count when the post
/// has comments the gates declined to animate.
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

    @Test func promptFillsTheZoneWheneverTheSurfacesAreSilent() throws {
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

    /// THE COMMON CASE, and the reason the floor exists. A sparse post's
    /// comments fail both surfaces' engagement gates, so the band and the
    /// zone both stand down — which used to leave an unexplained hole where
    /// the comment system should be. The pill fills it, and says the honest
    /// thing: the post HAS comments, here is how many.
    @Test func gatedButNonzeroPostsShowTheCount() throws {
        let chrome = makeChrome()
        let prompt = try emptyState(in: chrome)
        chrome.updateCommentStreams(FeedViewModel.CommentStreams(
            reactions: [], subtitles: [], commentCount: 2
        ))
        #expect(prompt.isHidden == false)
        #expect(prompt.accessibilityLabel == "2 comments")
    }

    /// The copy is the pill's whole job here — it must never claim "no
    /// comments" about a post that has them, and it writes numbers the way
    /// the subtitle zone's own count badge does.
    @Test func promptCopyTracksTheCount() {
        #expect(SnapCommentEmptyStateView.promptText(count: 0) == "No comments yet")
        #expect(SnapCommentEmptyStateView.promptText(count: 1) == "1 comment")
        #expect(SnapCommentEmptyStateView.promptText(count: 2) == "2 comments")
        // Past a thousand it abbreviates through the subtitle zone's
        // formatter, so the two comment surfaces never disagree.
        #expect(SnapCommentEmptyStateView.promptText(count: 1200) == "1.2k comments")
    }

    /// A count landing on an ALREADY-shown pill re-renders in place. The
    /// visibility guard used to be the first thing `setVisible` did, so a
    /// gated post gaining a comment would have kept the stale copy.
    @Test func countUpdatesInPlaceWithoutASecondEntrance() throws {
        let chrome = makeChrome()
        let prompt = try emptyState(in: chrome)
        chrome.updateCommentStreams(FeedViewModel.CommentStreams(
            reactions: [], subtitles: [], commentCount: 0
        ))
        #expect(prompt.accessibilityLabel == SnapCommentEmptyStateView.promptText)
        chrome.updateCommentStreams(FeedViewModel.CommentStreams(
            reactions: [], subtitles: [], commentCount: 1
        ))
        #expect(prompt.isHidden == false)
        #expect(prompt.accessibilityLabel == "1 comment")
    }

    /// A speaking surface owns the zone; the floor never doubles it. The
    /// subtitle zone alone (cues but no band-worthy reactions) is the case
    /// a count-only predicate would have got wrong.
    @Test func aSpeakingSurfaceKeepsTheFloorDown() throws {
        let chrome = makeChrome()
        let prompt = try emptyState(in: chrome)
        chrome.updateCommentStreams(FeedViewModel.CommentStreams(
            reactions: [],
            subtitles: (0..<3).map {
                SubtitleCue(id: "s\($0)", text: "A whole sentence worth reading \($0).")
            },
            commentCount: 3
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
