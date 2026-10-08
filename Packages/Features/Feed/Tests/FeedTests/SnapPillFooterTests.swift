import CoreModels
import MediaCore
import Testing
import UIKit
@testable import Feed

/// `-snap-pill-footer` (#671): the author pill leaves the nav bar for the
/// toolbar's leading slot; the column's lower bubble becomes the sound's.
///
/// ```
///  NAV      [‹] ……………………………… [points]
///  PAGE     … [♥]
///             [◉ sound]      tap: mute · hold: the sound sheet · 🔇 badge
///  TOOLBAR  [author pill] ……… [⇄ 🔖] [⋯]   ⋯: Share · Not interested · Report
/// ```
///
/// Each test turns the flag on BEFORE it builds a view and off before it
/// returns, with nothing awaited in between.
@MainActor
struct SnapPillFooterTests {
    private typealias Layout = SnapActionColumnLayoutTests

    private func withFooter<T>(_ body: () throws -> T) rethrows -> T {
        SnapPillFooter.isOn = true
        defer { SnapPillFooter.isOn = false }
        return try body()
    }

    private static func photo(_ id: String = "p1") -> FeedItemDisplayModel {
        FeedItemDisplayModel(
            id: PostID(id), authorID: ProfileID("a"), authorName: "Ava", metaText: "",
            avatarURL: nil, caption: "caption",
            mediaURL: URL(string: "https://example.test/a.jpg"), mediaKind: .image,
            thumbnailURL: URL(string: "https://example.test/a-thumb.jpg"), audioText: nil, likeCount: 0
        )
    }

    private static func text(_ id: String = "t1") -> FeedItemDisplayModel {
        FeedItemDisplayModel(
            id: PostID(id), authorID: ProfileID("a"), authorName: "Ava", metaText: "",
            avatarURL: nil, caption: "words", mediaURL: nil, mediaKind: .image,
            thumbnailURL: nil, audioText: nil
        )
    }

    private func feed() -> SnapFeedViewController {
        let controller = SnapFeedViewController(
            viewModel: FeedViewModel(repository: SilentFooterProvider()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            reporting: FooterReporter()
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.seedProjection([Self.photo()])
        controller.view.layoutIfNeeded()
        return controller
    }

    // MARK: - The bars

    /// `[author pill] … [⇄ 🔖] [⋯]`, and no pill in the nav bar.
    @Test func thePillLeadsTheToolbarAndLeavesTheNavBar() throws {
        try withFooter {
            let feed = feed()
            let items = try #require(feed.toolbarItems)
            #expect(items.count == 5, "the bar is [pill][flex][actions][fixed][⋯]: \(items.count)")
            #expect(items.first?.customView is SnapAuthorIdentityView)
            #expect(items[1].customView == nil, "a dynamic space after the pill")
            let actions = (items[2].customView?.subviews ?? []).compactMap { ($0 as? UIButton)?.accessibilityLabel }
            #expect(actions == ["Repost", "Save"], "the capsule is not [repost, save]: \(actions)")
            #expect((items.last?.customView as? UIButton)?.accessibilityLabel == "More actions")
            #expect(!items.contains { $0.customView is SnapMediaAttributionView }, "the audio capsule stayed")

            let nav = feed.navigationItem.rightBarButtonItems ?? []
            #expect(!nav.contains { $0.customView is SnapAuthorIdentityView }, "the pill is still in the nav bar")
        }
    }

    /// Share moved into ⋯, first.
    @Test func shareIsInTheMenu() {
        withFooter {
            #expect(feed().debugMoreMenuTitles(for: PostID("p1")) == ["Share", "Not interested", "Report"])
        }
    }

    /// Flag off: the bar and the menu are what they were.
    @Test func withoutTheFlagTheBarsAreUnchanged() throws {
        #expect(!SnapPillFooter.isOn)
        let feed = feed()
        let items = try #require(feed.toolbarItems)
        #expect(items.first?.customView is SnapMediaAttributionView)
        #expect(feed.navigationItem.rightBarButtonItems?.contains { $0.customView is SnapAuthorIdentityView } == true)
        #expect(feed.debugMoreMenuTitles(for: PostID("p1")) == ["Not interested", "Report"])
    }

    // MARK: - The sound bubble's face

    /// A media post with no audio wears a greyed bubble; a text post with no
    /// sound has none; the flag off, nobody has one.
    @Test func whoGetsASoundBubble() {
        withFooter {
            let feed = feed()
            let photo = feed.soundFace(for: Self.photo())
            #expect(photo?.isAvailable == false, "a photograph with no audio is not greyed")
            #expect(feed.soundFace(for: Self.text()) == nil, "a text post with no sound grew a bubble")
        }
        #expect(feed().soundFace(for: Self.photo()) == nil)
    }

    /// The bubble stands on the repost bubble's frame, which it replaces; a
    /// tap mutes, a hold opens the sheet, and the badge says when it is muted.
    @Test func theBubbleTakesTheRepostsPlace() {
        withFooter {
            let chrome = Layout.chrome()
            let bubble = chrome.debugSoundBubble
            #expect(bubble.isHidden, "a bubble with no face")

            var taps = 0
            var holds = 0
            chrome.onSoundTapped = { taps += 1 }
            chrome.onSoundSheetRequested = { holds += 1 }
            chrome.setSoundFace(SnapSoundFace(coverURL: nil, isAvailable: true, isMuted: false))
            chrome.layoutIfNeeded()
            #expect(!bubble.isHidden)
            #expect(chrome.debugRepostButton.isHidden, "the repost stayed on the page")
            #expect(bubble.frame == chrome.debugRepostButton.frame)
            #expect(bubble.debugCoverImage != nil, "the note did not draw")
            #expect(!bubble.debugIsMutedBadgeShown)

            bubble.sendActions(for: .primaryActionTriggered)
            #expect(taps == 1)
            bubble.onLongPress?()
            #expect(holds == 1)

            chrome.setSoundFace(SnapSoundFace(coverURL: nil, isAvailable: true, isMuted: true))
            #expect(bubble.debugIsMutedBadgeShown)

            chrome.setSoundFace(SnapSoundFace(coverURL: nil, isAvailable: false, isMuted: false))
            #expect(!bubble.isEnabled, "a post with no audio took the mute")
            #expect(bubble.alpha < 1)
        }
    }

    /// A text page's column is its composer's: no bubble on the page.
    @Test func aTextPageHasNoBubbleOnThePage() {
        withFooter {
            let chrome = Layout.chrome(mediaURL: nil)
            chrome.setSoundFace(SnapSoundFace(coverURL: nil, isAvailable: true, isMuted: false))
            #expect(chrome.debugSoundBubble.isHidden)
        }
    }

    // MARK: - The comments layout

    /// The composer's rail slot wears the sound's cover, on the sound
    /// bubble's frame.
    @Test func theRailSlotWearsTheCoverOnTheBubblesFrame() throws {
        try withFooter {
            let media = Layout.mediaColumn()
            let (controller, window) = Layout.engagedPanel()
            controller.setRailSoundFace(SnapSoundFace(coverURL: nil, isAvailable: true, isMuted: false))
            controller.view.layoutIfNeeded()
            let composer = try Layout.composerColumn(in: controller.view, space: window)
            #expect(composer.bar.debugRailSymbol == CommentsInputBar.soundRailSymbol)
            #expect(composer.rail == media.repost, "rail \(composer.rail) vs bubble \(media.repost)")

            controller.setRailSoundFace(nil)
            #expect(composer.bar.debugRailSymbol == nil, "a post with no sound kept a rail face")
        }
    }
}

private final class FooterReporter: ContentReporting, @unchecked Sendable {
    func report(_ subject: ReportSubject, reason: ReportReason, surface: String) async throws {}
}

private final class SilentFooterProvider: FeedProviding, @unchecked Sendable {
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
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
