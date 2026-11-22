import CoreModels
import CoreStorage
import DesignSystem
import MediaCore
import Testing
import UIKit
@testable import Feed
@testable import PostSurfaces
@testable import ThreadKit

/// The full-screen reader as the map, profiles and conversations push it:
/// the author pill in the toolbar, the danmaku over the stream, the bottom
/// block a breath over the toolbar. (Until #2453 this suite set it against
/// the For You root's layout, gone with the tab.)
@MainActor
struct SnapPushedPageChromeTests {
    private func feed() -> SnapFeedViewController {
        let controller = SnapFeedViewController(
            viewModel: FeedViewModel(repository: EmptyFeedProvider(), unavailablePosts: UnavailablePosts(viewerEvents: ViewerEvents())),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            bookmarks: PostBookmarkStore(scope: StorageScope()),
            savedSounds: SavedSoundStore(scope: StorageScope()),
            viewer: { nil }
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        controller.seedProjection([SnapActionColumnLayoutTests.mediaModel(mediaURL: URL(string: "mock://media/1"))])
        controller.view.layoutIfNeeded()
        return controller
    }

    // MARK: - The bars

    /// The feed keeps its toolbar and the author pill there.
    @Test func theToolbarCarriesTheAuthorPill() {
        let pushed = feed()
        pushed.setEngagedChrome(false, hasMedia: true, animated: false)
        #expect(pushed.toolbarItems?.first?.customView is SnapAuthorIdentityView)
        #expect(!(pushed.navigationItem.rightBarButtonItems ?? []).contains { $0.customView is SnapAuthorIdentityView })
    }

    // MARK: - The danmaku

    private static func streams(reactions: Int) -> FeedViewModel.CommentStreams {
        FeedViewModel.CommentStreams(
            reactions: (0..<reactions).map { TickerCommentModel(id: "r\($0)", text: "fire \($0)") },
            subtitles: [SubtitleCue(id: "s0", text: "A whole sentence worth reading.")],
            commentCount: reactions + 1
        )
    }

    private static func streamZone(of chrome: SnapChromeView) throws -> SnapSubtitleView {
        try #require(chrome.subviews.lazy.compactMap { $0 as? SnapSubtitleView }.first)
    }

    /// The danmaku rides above the stream, and the stream stays shown.
    @Test func theDanmakuRidesAboveTheStream() throws {
        let chrome = SnapActionColumnLayoutTests.chrome()
        chrome.configure(with: SnapActionColumnLayoutTests.mediaModel(mediaURL: URL(string: "mock://media/1")))
        let stream = try Self.streamZone(of: chrome)
        chrome.updateCommentStreams(Self.streams(reactions: 8))
        chrome.layoutIfNeeded()
        #expect(!stream.isHidden)
        #expect(chrome.debugTickerFrame.maxY <= chrome.debugStreamFrame.minY)
    }

    // MARK: - The bottom block (#1722)

    /// The bottom block stands a breath (6 pt, #1722) over the toolbar; strip
    /// or not, the column's bottom stands on the caption's letters' line
    /// (#2326), and the strip runs to the column's outer edge (#2291).
    @Test func theBottomBlockStandsOneBreathOverTheToolbar() {
        func laidOut(pages: Int) -> SnapChromeView {
            let chrome = SnapActionColumnLayoutTests.chrome()
            chrome.setSoundFace(SnapSoundFace(coverURL: nil, isAvailable: true))
            chrome.setMediaPageCount(pages, current: 0)
            chrome.setNeedsLayout()
            chrome.layoutIfNeeded()
            return chrome
        }
        func frame(_ view: UIView, in chrome: SnapChromeView) -> CGRect { view.convert(view.bounds, to: chrome) }
        let chrome = laidOut(pages: 9)
        let bar = frame(chrome.debugPageBar, in: chrome)
        let sound = frame(chrome.debugSoundBubble, in: chrome)
        // The strip runs the content's full width (#2291): under the cover,
        // to the column's outer edge, and below the cover's bottom.
        #expect(abs(bar.maxX - sound.maxX) < 0.5, "the strip does not end at the column's edge")
        #expect(bar.minY > sound.maxY, "the strip meets the cover")

        // The cover's bottom: the bar's line, less the breath and the rest
        // gap, less the column's lift onto the caption's line (#2326).
        let barLine = chrome.bounds.height - SnapActionColumnLayoutTests.insets.bottom
        let lift = SnapChromeGeometry.columnLineLift()
        #expect(abs(sound.maxY - (barLine - SnapActionColumn.bottomBreath - SnapActionColumn.inputRestingGap
            - lift)) < 0.5, "the cover is not its breath and its lift over the bar")
        // The cover's bottom on the caption's letters' line over a strip too
        // (#2326): one line for the caption and the column, as #2252 meant.
        let drop = SnapChromeGeometry.captionLetterDrop
        #expect(abs(chrome.debugCaptionFrame.maxY - drop - sound.maxY) < 0.5, "the cover is off the caption's line")

        let lone = laidOut(pages: 1)
        let loneSound = frame(lone.debugSoundBubble, in: lone)
        #expect(abs(lone.debugCaptionFrame.maxY - drop - loneSound.maxY) < 0.5, "with no strip the column left its seat")
        #expect(SnapActionColumnLayoutTests.same(loneSound, sound), "the column moved for the strip")
    }

    /// The no-strip caption and column take the same seat as over a strip:
    /// the column's bottom on the caption's letters' line (#2326; #2301 had
    /// the column on the composer's line, #1726 the caption on the column's
    /// bottom).
    @Test func theCaptionTakesItsSeatWithNoStrip() {
        let chrome = SnapActionColumnLayoutTests.chrome()
        chrome.setSoundFace(SnapSoundFace(coverURL: nil, isAvailable: true))
        chrome.setMediaPageCount(1, current: 0)
        chrome.setNeedsLayout()
        chrome.layoutIfNeeded()
        let cover = chrome.debugSoundBubble.convert(chrome.debugSoundBubble.bounds, to: chrome)
        let letters = chrome.debugCaptionFrame.maxY - SnapChromeGeometry.captionLetterDrop
        #expect(abs(cover.maxY - letters) < 0.5, "the column is off the caption's line")
    }
}

private final class EmptyFeedProvider: FeedProviding, @unchecked Sendable {
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPage(afterToken token: String) async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPost(_ id: PostID) async throws -> FeedEntry {
        FeedEntry(
            post: Post(id: id, authorID: ProfileID("p"), caption: "", attachments: [], publishedAt: Date(timeIntervalSince1970: 0)),
            author: AuthorSummary(id: ProfileID("p"), handle: "ava", displayName: "Ava", avatarURL: nil),
            likeCount: 0
        )
    }
}
