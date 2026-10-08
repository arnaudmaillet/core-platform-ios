import CoreModels
import DesignSystem
import MediaCore
import Testing
import UIKit
@testable import Feed

/// ONE action column for the media and comments layouts (#695): the page's
/// like pill and sound bubble stay on screen when the comments take the page,
/// and the composer only reserves their room — no second copy to crossfade.
@MainActor
struct SnapSharedColumnTests {
    private typealias Layout = SnapActionColumnLayoutTests

    private static func media(_ id: String = "p") -> FeedItemDisplayModel {
        FeedItemDisplayModel(
            id: PostID(id), authorID: ProfileID("a"), authorName: "Ava", metaText: "",
            avatarURL: nil, caption: "caption",
            mediaURL: URL(string: "mock://media/1"), mediaKind: .image,
            thumbnailURL: nil, audioText: nil, likeCount: 12
        )
    }

    /// A chrome mounted the way a cell mounts it: its column in the host,
    /// above it.
    private static func mounted(_ model: FeedItemDisplayModel = media()) -> (chrome: SnapChromeView, host: UIView, window: UIWindow) {
        let window = UIWindow(frame: Layout.screen)
        window.overrideUserInterfaceStyle = .light
        window.isHidden = false
        let host = UIView(frame: Layout.screen)
        window.addSubview(host)
        let chrome = SnapChromeView(frame: Layout.screen)
        chrome.setFixedInsets(Layout.insets)
        host.addSubview(chrome)
        chrome.installActionColumn(in: host)
        chrome.configure(with: model)
        chrome.setSoundFace(SnapSoundFace(coverURL: nil, isAvailable: true, isMuted: false))
        host.layoutIfNeeded()
        return (chrome, host, window)
    }

    /// Visible as drawn: shown, and no ancestor faded to nothing.
    private static func isDrawn(_ view: UIView) -> Bool {
        var current: UIView? = view
        while let node = current {
            if node.isHidden || node.alpha < 0.01 { return false }
            current = node.superview
        }
        return true
    }

    // MARK: - The page's column

    /// ⚠️ THE COMMENTS TAKE THE CHROME, NOT THE COLUMN: engaged, the chrome
    /// is at zero and the same pill and bubble are still drawn, on the same
    /// frames, above it.
    @Test func theColumnStaysWhenTheCommentsTakeThePage() {
        let (chrome, _, window) = Self.mounted()
        defer { window.isHidden = true }
        let pill = chrome.debugBoostButton
        let bubble = chrome.debugSoundBubble
        let frames = (pill.frame, bubble.frame)
        #expect(!pill.isDescendant(of: chrome), "the column is still inside the chrome it fades with")

        chrome.setCommentsEngaged(true)
        #expect(chrome.alpha == 0)
        #expect(Self.isDrawn(pill), "the like pill left with the chrome")
        #expect(Self.isDrawn(bubble), "the sound bubble left with the chrome")
        #expect(chrome.debugBoostButton === pill && chrome.debugSoundBubble === bubble)
        #expect(pill.frame == frames.0 && bubble.frame == frames.1, "the column moved")

        chrome.setCommentsEngaged(false)
        #expect(Self.isDrawn(pill) && Self.isDrawn(bubble))
    }

    /// The column's frames are the stations the chrome kept: the same as
    /// a chrome that carries its column itself (the flight's replica).
    @Test func theMountedColumnStandsOnTheStations() {
        let (mounted, _, window) = Self.mounted()
        defer { window.isHidden = true }
        let replica = Layout.chrome()
        replica.setSoundFace(SnapSoundFace(coverURL: nil, isAvailable: true, isMuted: false))
        replica.layoutIfNeeded()
        #expect(Layout.same(mounted.debugBoostButton.frame, replica.debugBoostButton.frame))
        #expect(Layout.same(mounted.debugSoundBubble.frame, replica.debugSoundBubble.frame))
    }

    /// A flight holds the column with the page — engaged or not — and
    /// gives it back.
    @Test func aFlightHoldsTheColumn() {
        let (chrome, _, window) = Self.mounted()
        defer { window.isHidden = true }
        chrome.setCommentsEngaged(true)
        chrome.setColumnHeld(true)
        #expect(!Self.isDrawn(chrome.debugBoostButton))
        chrome.setColumnHeld(false)
        #expect(Self.isDrawn(chrome.debugBoostButton), "the engaged column did not come back after the flight")
    }

    /// The ink: dark glass on a media page in both layouts, a text page's
    /// own theme.
    @Test func theInkFollowsTheLayout() {
        let (chrome, host, window) = Self.mounted()
        defer { window.isHidden = true }
        let pill = chrome.debugBoostButton
        // Traits reach a subtree on its next layout pass.
        func style() -> UIUserInterfaceStyle {
            host.setNeedsLayout()
            host.layoutIfNeeded()
            pill.layoutIfNeeded()
            return pill.traitCollection.userInterfaceStyle
        }
        #expect(style() == .dark)
        // ⚠️ STILL DARK with the comments up (the owner, on a device): the
        // column is the media's, in both layouts.
        chrome.setCommentsEngaged(true)
        #expect(style() == .dark, "engaged, the column turned light")
        chrome.setCommentsEngaged(false)
        #expect(style() == .dark)

        let (text, _, textWindow) = Self.mounted(FeedItemDisplayModel(
            id: PostID("t"), authorID: ProfileID("a"), authorName: "Ava", metaText: "",
            avatarURL: nil, caption: "words", mediaURL: nil, mediaKind: .image,
            thumbnailURL: nil, audioText: nil, likeCount: 3
        ))
        defer { textWindow.isHidden = true }
        #expect(text.debugBoostButton.traitCollection.userInterfaceStyle == .light)
        #expect(Self.isDrawn(text.debugBoostButton), "a text page has no pill")
    }

    /// The cell mounts the column in its own content, ABOVE its chrome and
    /// its comments: it rides the page when the viewer swipes between posts,
    /// and the panel never covers it.
    @Test func theCellMountsTheColumnAboveItsChrome() throws {
        let cell = SnapFeedCell(frame: Layout.screen)
        let subviews = cell.contentView.subviews
        let column = try #require(subviews.firstIndex { $0 is SnapActionColumnLayer }, "no column in the cell")
        let chrome = try #require(subviews.firstIndex { $0 is SnapChromeView })
        #expect(chrome < column, "the column is under the chrome that fades")
        #expect(subviews[column].subviews.contains { $0 is SnapRailBoostButton })
        #expect(subviews[column].subviews.contains { $0 is SnapSoundBubbleButton })
    }

    // MARK: - The composer's reserved room

    /// ⚠️ RESERVED, NOT DRAWN: the composer keeps the stations — the same
    /// frames, so the field still stops short of the column — draws nothing
    /// there and takes no touch there.
    @Test func theComposerOnlyReservesTheColumn() throws {
        let (inline, window) = Layout.engagedPanel()
        defer { window.isHidden = true }
        let drawn = try Layout.composerColumn(in: inline.view, space: window)

        let (reserved, reservedWindow) = Layout.engagedPanel()
        defer { reservedWindow.isHidden = true }
        reserved.setActionColumnHostedByPage(true)
        reserved.view.layoutIfNeeded()
        let kept = try Layout.composerColumn(in: reserved.view, space: reservedWindow)
        #expect(Layout.same(kept.rail, drawn.rail))
        #expect(Layout.same(kept.field, drawn.field), "the field took the column's room")

        let bar = kept.bar
        let stake = try #require(Layout.button(bar, "Like"))
        #expect(bar.debugRailButton.alpha == 0 && stake.alpha == 0, "the composer still draws a column")
        let inStake = CGPoint(x: stake.frame.midX, y: stake.frame.midY)
        #expect(!bar.point(inside: inStake, with: nil), "the reserved stake still takes touches")
    }

    /// The snap feed's panels reserve; the loading page, which has no page
    /// above it, keeps its own.
    @Test func theFeedsPanelsReserveTheColumn() throws {
        let feed = SnapFeedViewController(
            viewModel: FeedViewModel(repository: SharedColumnSilentProvider()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        feed.loadViewIfNeeded()
        feed.seedProjection([Self.media()])

        let (panel, window) = Layout.engagedPanel()
        defer { window.isHidden = true }
        feed.applySoundRail(to: panel)
        let bar = try Layout.composerColumn(in: panel.view, space: window).bar
        #expect(!bar.hostsActionColumn)

        let (loading, loadingWindow) = Layout.engagedPanel()
        defer { loadingWindow.isHidden = true }
        feed.applySoundRail(to: loading, hostedByPage: false)
        #expect(try Layout.composerColumn(in: loading.view, space: loadingWindow).bar.hostsActionColumn)
    }
}

/// A repository that vends nothing: these tests are about the column.
private final class SharedColumnSilentProvider: FeedProviding, @unchecked Sendable {
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPage(afterToken token: String) async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPost(_ id: PostID) async throws -> FeedEntry { throw CancellationError() }
}
