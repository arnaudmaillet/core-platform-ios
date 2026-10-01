import CoreModels
import DesignSystem
import MediaCore
import Testing
import UIKit
@testable import Feed

/// **`-snap-layout-v2`: the action column holds still across layouts.**
///
/// ```
///   media layout                         comments layout
///   ~~~~ band ~~~~~~~~~~~~~~ [♥]          ———————————————————— [♥]
///   caption…                 [⇪]          [☺][field…        ] [〰]
/// ```
///
/// The like anchor and the share bubble are constraints inside the page's
/// chrome; the composer's stake and mic/send are constraints inside the
/// comments panel, resting on a line computed from the column's numbers. The
/// two never see each other — so the only proof they agree is to lay both out
/// at one screen size and compare the frames. Equal frames are what "switching
/// layouts, the bubbles don't move" means.
@MainActor
struct SnapActionColumnLayoutTests {
    static let screen = CGRect(x: 0, y: 0, width: 390, height: 844)
    /// A notched phone's nav-bar top and its home indicator + floating
    /// toolbar — the feed's safe area while its footer is up.
    static let insets = UIEdgeInsets(top: 103, left: 0, bottom: 83, right: 0)

    // MARK: - Fixtures

    static func mediaModel(mediaURL: URL? = URL(string: "mock://media/1")) -> FeedItemDisplayModel {
        FeedItemDisplayModel(
            id: PostID("post-1"), authorID: ProfileID("profile-1"), authorName: "Ana",
            metaText: "@ana · 3m", avatarURL: nil,
            caption: "A caption long enough to fill both of its lines beside the reserved floor.",
            mediaURL: mediaURL, mediaKind: .image, thumbnailURL: nil, audioText: nil
        )
    }

    /// The media layout at full screen, as a page lays it out (the chrome IS
    /// the page's overlay, edge to edge — its coordinates are the screen's).
    static func chrome(
        actionColumn: Bool, insets: UIEdgeInsets = insets, mediaURL: URL? = URL(string: "mock://media/1")
    ) -> SnapChromeView {
        let chrome = SnapChromeView(frame: screen)
        chrome.usesActionColumn = actionColumn
        chrome.setFixedInsets(insets)
        chrome.configure(with: mediaModel(mediaURL: mediaURL))
        chrome.layoutIfNeeded()
        return chrome
    }

    /// The media layout's two bubbles, in screen coordinates.
    static func mediaColumn(insets: UIEdgeInsets = insets) -> (like: CGRect, share: CGRect) {
        let chrome = chrome(actionColumn: true, insets: insets)
        return (chrome.debugBoostButton.frame, chrome.debugShareButton.frame)
    }

    /// The composer's two bubbles, in `space`.
    static func composerColumn(in root: UIView, space: UICoordinateSpace) throws -> (stake: CGRect, mic: CGRect, bar: CommentsInputBar) {
        let bar = try #require(firstView(CommentsInputBar.self, in: root))
        let stake = try #require(button(bar, "Boost post"))
        let mic = try #require(button(bar, "Record voice comment"))
        return (stake.convert(stake.bounds, to: space), mic.convert(mic.bounds, to: space), bar)
    }

    static func button(_ bar: UIView, _ label: String) -> UIButton? {
        bar.subviews.compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == label }
    }

    static func firstView<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = firstView(type, in: subview) { return match }
        }
        return nil
    }

    private func detail(actionColumn: Bool) -> PostDetailViewController {
        let controller = PostDetailViewController(
            viewModel: PostDetailViewModel(postID: PostID("p"), repository: ColumnSilentProvider()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            mode: .commentsOnly
        )
        controller.usesActionColumn = actionColumn
        return controller
    }

    /// The engaged comments panel, mounted the way the feed mounts it: full
    /// screen, told the feed's insets.
    private func engagedPanel(actionColumn: Bool) -> (PostDetailViewController, UIWindow) {
        let controller = detail(actionColumn: actionColumn)
        let window = UIWindow(frame: Self.screen)
        window.rootViewController = controller
        window.isHidden = false
        controller.view.frame = Self.screen
        controller.setEngagedPageSwipeHandler { _, _, _ in }
        controller.setEngagedInsets(top: 200, bottomInset: Self.insets.bottom)
        controller.setComposerEntranceState(offstage: false)
        controller.view.layoutIfNeeded()
        return (controller, window)
    }

    // MARK: - Flag off: nothing changes

    /// Off, the chrome carries no share bubble at all — not even hidden — and
    /// the caption runs to its classic margin.
    @Test func withoutTheFlagThePageHasNoShareBubble() {
        let chrome = Self.chrome(actionColumn: false)
        #expect(!chrome.subviews.contains { $0 is SnapRailShareButton })
        #expect(chrome.interactionRoots.count == 5)
        #expect(abs(chrome.debugCaptionFrame.maxX - (Self.screen.width - Spacing.lg)) < 0.5)
    }

    @Test func withoutTheFlagTheComposerKeepsItsClassicBubbles() throws {
        let bar = CommentsInputBar()
        bar.frame = CGRect(x: 0, y: 0, width: 340, height: CommentsInputBar.restingHeight(for: .large))
        bar.layoutIfNeeded()
        let stake = try #require(Self.button(bar, "Boost post"))
        let mic = try #require(Self.button(bar, "Record voice comment"))
        #expect(stake.frame.size == CGSize(width: 44, height: 44))
        #expect(mic.frame.size == CGSize(width: 38, height: 38))
        let glyph = mic.configuration?.image.map { String(describing: $0) } ?? ""
        #expect(!glyph.contains("waveform"))
    }

    // MARK: - The media layout

    /// The share bubble is the like anchor's twin, one md under it, and the
    /// caption and the page strip stop md short of it.
    @Test func theShareBubbleStandsUnderTheLikeBubbleBesideTheCaption() {
        let chrome = Self.chrome(actionColumn: true)
        let like = chrome.debugBoostButton.frame
        let share = chrome.debugShareButton.frame

        #expect(chrome.debugShareButton.isHidden == false)
        #expect(share.size == like.size)
        #expect(abs(share.width - SnapActionColumn.bubbleSize) < 0.5)
        #expect(share.maxX == like.maxX)
        #expect(abs(share.minY - (like.maxY + SnapActionColumn.gap)) < 0.5)
        #expect(chrome.debugCaptionFrame.maxX <= share.minX - Spacing.md + 0.5)
        // Its top is the caption floor's: beside the caption's first line.
        #expect(abs(chrome.debugCaptionFrame.maxY - (share.minY + SnapChromeView.captionFloorHeight)) < 0.5)
        #expect(chrome.debugPageBarFrame.maxX == chrome.debugCaptionFrame.maxX)
        #expect(chrome.interactionRoots.contains { $0 === chrome.debugShareButton })
    }

    /// Media chrome, like the anchor: a text page's composer stands in the
    /// column instead.
    @Test func aTextPageHasNoShareBubble() {
        let chrome = Self.chrome(actionColumn: true, mediaURL: nil)
        #expect(chrome.debugShareButton.isHidden)
    }

    @Test func aTapOnTheShareBubbleAsksToShare() {
        let chrome = Self.chrome(actionColumn: true)
        var asked = 0
        chrome.onShareRequested = { asked += 1 }
        chrome.debugShareButton.sendActions(for: .primaryActionTriggered)
        #expect(asked == 1)
    }

    // MARK: - The comments layout

    /// ⚠️ THE CONTRACT. The engaged composer's stake sits on the like
    /// bubble's frame and its mic/send on the share bubble's, in screen
    /// coordinates — equal, not close.
    @Test func theComposerBubblesStandExactlyOnTheMediaLayoutsBubbles() throws {
        let media = Self.mediaColumn()
        let (controller, window) = engagedPanel(actionColumn: true)
        let composer = try Self.composerColumn(in: controller.view, space: window)

        #expect(composer.stake == media.like, "stake \(composer.stake) vs like \(media.like)")
        #expect(composer.mic == media.share, "mic \(composer.mic) vs share \(media.share)")
        _ = window
    }

    /// The column's entrance is alpha only — a slide would move the bubbles.
    @Test func theColumnComposerEntersWithoutSliding() {
        let (controller, window) = engagedPanel(actionColumn: true)
        controller.setComposerEntranceState(offstage: true)
        let bar = Self.firstView(CommentsInputBar.self, in: controller.view)
        #expect(bar?.alpha == 0)
        #expect(bar?.transform == .identity)
        _ = window
    }

    /// The bar's own geometry: both bubbles the band's height, md apart, the
    /// mic a waveform, and a field that grows BESIDE the stake, never moving it.
    @Test func theColumnBarHoldsTheStakeStillWhileTheFieldGrows() throws {
        let bar = CommentsInputBar()
        bar.usesActionColumn = true
        bar.onPageSwipe = { _, _, _ in }
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 360, height: 600))
        host.addSubview(bar)
        bar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        host.layoutIfNeeded()

        let stake = try #require(Self.button(bar, "Boost post"))
        let mic = try #require(Self.button(bar, "Record voice comment"))
        let side = SnapActionColumn.bubbleSize
        #expect(stake.frame.size == CGSize(width: side, height: side))
        #expect(mic.frame.size == CGSize(width: side, height: side))
        #expect(abs(mic.frame.minY - stake.frame.maxY - SnapActionColumn.gap) < 0.5)
        let glyph = mic.configuration?.image.map { String(describing: $0) } ?? ""
        #expect(glyph.contains("waveform"), "the mic wears \(glyph)")
        #expect(abs(bar.bounds.height - CommentsInputBar.restingHeight(for: .large, actionColumn: true)) < 0.5)
        #expect(!bar.hasAmbiguousLayout)

        let stakeInHost = stake.convert(stake.bounds, to: host)
        bar.draftText = Array(repeating: "A line that wraps", count: 8).joined(separator: " ")
        host.layoutIfNeeded()
        #expect(stake.convert(stake.bounds, to: host) == stakeInHost, "the stake moved as the field grew")
        #expect(!bar.hasAmbiguousLayout)
    }

    // MARK: - The menu

    /// Share has its own bubble, so ⋯ stops offering it.
    @Test func theMenuDropsShareWhenTheColumnCarriesIt() {
        let controller = SnapFeedViewController(
            viewModel: FeedViewModel(repository: ColumnSilentProvider()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            reporting: nil
        )
        controller.usesActionColumn = true
        #expect(controller.debugMoreMenuTitles(for: PostID("p1")) == ["Not interested"])
        controller.usesActionColumn = false
        #expect(controller.debugMoreMenuTitles(for: PostID("p1")) == ["Share", "Not interested"])
    }
}

/// A repository that vends nothing: these tests are about geometry.
private final class ColumnSilentProvider: FeedProviding, @unchecked Sendable {
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPage(afterToken token: String) async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPost(_ id: PostID) async throws -> FeedEntry {
        FeedEntry(
            post: Post(
                id: id, authorID: ProfileID("p"), caption: "",
                attachments: [], publishedAt: Date(timeIntervalSince1970: 0)
            ),
            author: AuthorSummary(
                id: ProfileID("p"), handle: "ava", displayName: "Ava", avatarURL: nil
            ),
            likeCount: 0
        )
    }
}
