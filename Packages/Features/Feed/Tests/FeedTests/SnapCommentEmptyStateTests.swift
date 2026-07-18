import CoreModels
import DesignSystem
import Testing
import UIKit
@testable import Feed

/// The comments empty state's visibility contract: the "No comments yet"
/// pill renders exactly when a media post's streams are LOADED with a zero
/// count — never on the pre-load `.empty` default (no flash while a fetch
/// is in flight), never on a gated-but-nonzero post (the surfaces' quiet
/// is deliberate there), and never on a text-only page (the empty shell).
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
        // pull's state): blank zone, no prompt.
        #expect(prompt.isHidden == true)
        chrome.updateCommentStreams(.empty)
        #expect(prompt.isHidden == true)

        // A loaded zero-comment stream is the one admitting state…
        chrome.updateCommentStreams(FeedViewModel.CommentStreams(
            reactions: [], subtitles: [], commentCount: 0
        ))
        #expect(prompt.isHidden == false)

        // …and comments arriving (e.g. the viewer composed one) retire it.
        chrome.updateCommentStreams(FeedViewModel.CommentStreams(
            reactions: (0..<8).map { TickerCommentModel(id: "c\($0)", text: "fire \($0)") },
            subtitles: [],
            commentCount: 8
        ))
        #expect(prompt.isHidden == true)
    }

    /// Gated-but-nonzero posts (below both surfaces' engagement minimums)
    /// keep their deliberate quiet: the zone is blank because the gates
    /// chose so, not because there is nothing to say.
    @Test func sparseButNonzeroPostsShowNoPrompt() throws {
        let chrome = makeChrome()
        let prompt = try emptyState(in: chrome)
        chrome.updateCommentStreams(FeedViewModel.CommentStreams(
            reactions: [], subtitles: [], commentCount: 2
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
        #expect(prompt.frame.maxY == captionFrameBefore.minY - Spacing.sm)
        #expect(prompt.frame.minX == caption.frame.minX)
        #expect(prompt.frame.height > 0)
    }
}
