import CoreModels
import DesignSystem
import Testing
import UIKit
@testable import Feed

/// The page's bottom scrim protects the caption block and leaves the picture
/// alone above it (#1983): its top is the block's top less the fade — the
/// caption on a pushed post, the author row on Shots — and nothing else
/// moves it.
@MainActor
struct SnapPageScrimTests {
    private func makeChrome(
        caption: String? = "Golden hour at the pier",
        timestamp: String = "2h",
        mediaURL: URL? = URL(string: "mock://photo/single-04"),
        showsAuthorRow: Bool = false
    ) -> SnapChromeView {
        let chrome = SnapChromeView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        chrome.showsAuthorRow = showsAuthorRow
        chrome.configure(with: FeedItemDisplayModel(
            id: PostID("post-0004"),
            authorID: ProfileID("profile-1"),
            authorName: "Vera Lindqvist",
            metaText: "@vera · 2h",
            avatarURL: nil,
            caption: caption,
            mediaURL: mediaURL,
            mediaKind: .image,
            thumbnailURL: nil,
            audioText: nil,
            timestampText: timestamp
        ))
        chrome.layoutIfNeeded()
        return chrome
    }

    private func frame(of view: UIView, in chrome: SnapChromeView) -> CGRect {
        view.convert(view.bounds, to: chrome)
    }

    private func scrimTop(_ chrome: SnapChromeView) -> CGFloat {
        frame(of: chrome.debugScrimView, in: chrome).minY
    }

    @Test func onAPushedPostTheScrimStartsAtTheCaptionLessTheFade() {
        let chrome = makeChrome()
        let caption = frame(of: chrome.debugCaptionLabel, in: chrome)
        #expect(abs(scrimTop(chrome) - (caption.minY - SnapChromeView.scrimFade)) < 0.5)
        #expect(frame(of: chrome.debugScrimView, in: chrome).maxY == chrome.bounds.maxY)
    }

    @Test func aTimestampAloneIsTheBlock() {
        let chrome = makeChrome(caption: nil)
        let caption = frame(of: chrome.debugCaptionLabel, in: chrome)
        #expect(abs(scrimTop(chrome) - (caption.minY - SnapChromeView.scrimFade)) < 0.5)
    }

    @Test func onShotsTheScrimStartsAtTheAuthorRowLessTheFade() {
        let chrome = makeChrome(showsAuthorRow: true)
        let author = frame(of: chrome.debugAuthorRow, in: chrome)
        #expect(!chrome.debugAuthorRow.isHidden)
        #expect(abs(scrimTop(chrome) - (author.minY - SnapChromeView.scrimFade)) < 0.5)
        #expect(scrimTop(chrome) < frame(of: chrome.debugCaptionLabel, in: chrome).minY - SnapChromeView.scrimFade)
    }

    /// The measurement in the issue: the middle of the screen read 0.80 of the
    /// picture, because the scrim began at 32 % of it.
    @Test func theMiddleOfThePageIsNotUnderTheScrim() {
        for chrome in [makeChrome(), makeChrome(showsAuthorRow: true)] {
            #expect(scrimTop(chrome) > chrome.bounds.midY, "the scrim starts at \(scrimTop(chrome))")
        }
    }

    @Test func aTextPostHasNoScrim() {
        let chrome = makeChrome(mediaURL: nil)
        #expect(chrome.debugScrimView.isHidden)
    }

    /// The comment surfaces sit above the caption and no longer get the
    /// scrim (the owner's decision): shown or not, it stays where it is.
    @Test func theCommentSurfacesDoNotMoveIt() {
        let chrome = makeChrome()
        let before = scrimTop(chrome)
        chrome.updateCommentStreams(FeedViewModel.CommentStreams(
            reactions: (0..<6).map { TickerCommentModel(id: "c\($0)", text: "fire \($0)") },
            subtitles: [SubtitleCue(id: "a", text: "A longer semantic thought worth reading.", at: nil)],
            commentCount: 7
        ))
        chrome.layoutIfNeeded()
        #expect(scrimTop(chrome) == before)
        chrome.updateCommentStreams(FeedViewModel.CommentStreams(reactions: [], subtitles: [], commentCount: 0))
        chrome.layoutIfNeeded()
        #expect(scrimTop(chrome) == before)
    }

    /// A taller caption block takes the scrim up with it.
    @Test func aLongerCaptionMovesIt() {
        let short = makeChrome(caption: "Pier.")
        let long = makeChrome(caption: String(repeating: "Golden hour at the pier, the light going amber. ", count: 4))
        #expect(scrimTop(long) < scrimTop(short))
        let caption = frame(of: long.debugCaptionLabel, in: long)
        #expect(abs(scrimTop(long) - (caption.minY - SnapChromeView.scrimFade)) < 0.5)
    }

    /// The flight's replica and the live page are two chromes configured
    /// alike: one layout, one top.
    @Test func theReplicaAndTheLivePageAgree() {
        #expect(scrimTop(makeChrome()) == scrimTop(makeChrome()))
        #expect(scrimTop(makeChrome(showsAuthorRow: true)) == scrimTop(makeChrome(showsAuthorRow: true)))
    }

    /// The fade begins clear and eases in, so its edge cannot be seen.
    @Test func theFadeEasesInFromClear() {
        let alphas = SnapChromeView.scrimFadeColors.map { $0.cgColor.alpha }
        #expect(alphas.first == 0)
        #expect(abs((alphas.last ?? 0) - SnapChromeView.scrimBlockAlpha) < 0.001)
        #expect(zip(alphas, alphas.dropFirst()).allSatisfy { $0 < $1 })
        // Ease-in: the first half of the fade carries less than half the darkness.
        #expect(alphas[2] < SnapChromeView.scrimBlockAlpha / 2)
    }
}
