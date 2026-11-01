import CoreModels
import DesignSystem
import FeedInterface
import MediaCore
import Testing
import UIKit
@testable import Feed

/// The composer's rail slot wears the post's sound (#671) and answers as the
/// page's sound bubble does: a TAP opens the sound sheet, a LONG PRESS toggles
/// the feed's sound (#683, swapped from #680). On a text page the slot is the
/// only place the sound lives.
@MainActor
struct SnapComposerSoundSlotTests {
    private typealias Layout = SnapActionColumnLayoutTests
    private static let face = SnapSoundFace(coverURL: nil, isAvailable: true)

    /// A tap on the slot is the host's action, whatever the slot wears.
    @Test func aTapOnTheSoundSlotIsTheHostsAction() {
        let bar = CommentsInputBar()
        bar.railFace = .sound(Self.face)
        var taps = 0
        bar.onRailAction = { taps += 1 }
        bar.debugRailButton.sendActions(for: .primaryActionTriggered)
        #expect(taps == 1)
    }

    /// A hold (the mute) reaches the host only from a sound the post plays: a
    /// greyed sound and the other faces ignore it.
    @Test func aHoldOpensTheSheetOnlyFromAnAvailableSound() throws {
        let bar = CommentsInputBar()
        var holds = 0
        bar.onRailLongPress = { holds += 1 }
        let hold = try #require(
            bar.debugRailButton.gestureRecognizers?.compactMap { $0 as? UILongPressGestureRecognizer }.first
        )
        #expect(abs(hold.minimumPressDuration - 0.4) < 0.01)

        bar.railFace = .sound(Self.face)
        bar.debugHoldRail()
        #expect(holds == 1)
        bar.railFace = .sound(SnapSoundFace(coverURL: nil, isAvailable: false))
        bar.debugHoldRail()
        #expect(holds == 1, "a sound the post does not play took the mute")
        bar.railFace = .pin(isPinned: false)
        bar.debugHoldRail()
        #expect(holds == 1, "the pin took the mute")
    }

    /// The post screen hands both to its composer.
    @Test func thePostScreenWiresBothToItsComposer() throws {
        let (controller, window) = Layout.engagedPanel()
        defer { window.isHidden = true }
        var taps = 0
        var holds = 0
        controller.setRailSoundFace(Self.face)
        controller.setRailSoundActions(tap: { taps += 1 }, hold: { holds += 1 })
        let bar = try Layout.composerColumn(in: controller.view, space: window).bar
        bar.debugRailButton.sendActions(for: .primaryActionTriggered)
        bar.debugHoldRail()
        #expect(taps == 1)
        #expect(holds == 1)
    }

    private func feed(root: Bool, model: FeedItemDisplayModel) -> SnapFeedViewController {
        let feed = SnapFeedViewController(
            viewModel: FeedViewModel(repository: SlotSilentProvider()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            soundProvider: SlotSoundProvider()
        )
        feed.isForYouRoot = root
        feed.loadViewIfNeeded()
        feed.seedProjection([model])
        return feed
    }

    private static let textPage = FeedItemDisplayModel(
        id: PostID("p"), authorID: ProfileID("a"), authorName: "Ava", metaText: "",
        avatarURL: nil, caption: "A text page", mediaURL: nil, mediaKind: .image,
        thumbnailURL: nil, audioText: nil, likeCount: 3
    )

    private static let mediaPage = FeedItemDisplayModel(
        id: PostID("p"), authorID: ProfileID("a"), authorName: "Ava", metaText: "",
        avatarURL: nil, caption: "A photo", mediaURL: URL(string: "https://example.test/a.jpg"), mediaKind: .image,
        thumbnailURL: nil, audioText: nil, likeCount: 3
    )

    /// ⚠️ THE SLOT'S ONE DECISION (#1999, `applyRailSlot`): a pushed text
    /// page wears Share — never its sound, even one the provider names — a
    /// text page of the For You root has no slot, and a media page wears its
    /// sound. (Rewritten from #1929's "a text page's slot opens the sheet".)
    @Test func theSlotIsShareOnAPushedTextPageNoneOnTheRootAndTheSoundOnMedia() throws {
        let (panel, window) = Layout.engagedPanel()
        defer { window.isHidden = true }

        feed(root: false, model: Self.textPage).applyRailSlot(to: panel)
        let bar = try Layout.composerColumn(in: panel.view, space: window).bar
        #expect(bar.railFace == .share, "a pushed text page's slot is not Share")
        #expect(bar.debugRailButton.accessibilityLabel == "Share")
        #expect(bar.debugRailButton.accessibilityIdentifier == SnapFooterToolbar.ID.share)
        #expect(bar.onRailLongPress == nil, "the slot's hold still does something")

        feed(root: true, model: Self.textPage).applyRailSlot(to: panel)
        #expect(bar.railFace == .noSlot, "a text page of the For You root kept a slot")

        feed(root: false, model: Self.mediaPage).applyRailSlot(to: panel)
        guard case .sound = bar.railFace else {
            Issue.record("a media page's slot is not its sound: \(bar.railFace)")
            return
        }
        #expect(bar.debugRailButton.accessibilityIdentifier == nil)
    }

    /// ⚠️ A TEXT PAGE'S RECORD TURNS (#692): the slot's cover turns while
    /// asked to and stops when asked to; its mute badge never turns; another
    /// face, or a post with no sound, never turns.
    @Test func theSlotsRecordTurnsWithTheSound() {
        guard !MotionPreference.reducesMotion else { return }
        let bar = CommentsInputBar()
        bar.frame = CGRect(x: 0, y: 0, width: 360, height: 120)
        bar.railFace = .sound(Self.face)
        bar.layoutIfNeeded()
        #expect(!bar.debugRailCover.isHidden, "the cover is not drawn on the slot")
        #expect(bar.debugRailButton.configuration?.image == nil, "the cover is still the button's image")

        bar.setRailSpinning(true)
        #expect(bar.debugRailIsSpinning)
        bar.setRailSpinning(false)
        #expect(!bar.debugRailIsSpinning)

        bar.railFace = .sound(SnapSoundFace(coverURL: nil, isAvailable: true))
        bar.setRailSpinning(true)
        #expect(bar.debugRailIsSpinning)

        bar.railFace = .sound(SnapSoundFace(coverURL: nil, isAvailable: false))
        bar.setRailSpinning(true)
        #expect(!bar.debugRailIsSpinning, "a post with no sound turned")
        bar.railFace = .pin(isPinned: false)
        #expect(bar.debugRailCover.isHidden)
        #expect(!bar.debugRailIsSpinning)
    }

    /// ⚠️ A FILE COVER IS READ, NEVER FETCHED (#680): the slot and the bubble
    /// draw a mock poster at once; a remote cover waits for its fetch.
    @Test func aFileCoverIsDrawnAtOnce() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("slot-cover-\(UUID().uuidString).png")
        let poster = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        try #require(poster.pngData()).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let file = SnapSoundFace(coverURL: url, isAvailable: true)
        #expect(file.localCover != nil)

        let remote = SnapSoundFace(
            coverURL: URL(string: "https://example.test/\(UUID().uuidString).jpg"),
            isAvailable: true
        )
        #expect(remote.localCover == nil, "a remote cover drew before its fetch")
    }
}

private struct SlotSoundProvider: PostSoundProviding {
    func sound(forPost postID: PostID) -> PostSound? {
        PostSound(id: "song-1", title: "Song", artist: "Artist", previewURL: nil, artworkURL: nil, duration: 30)
    }

    func postIDs(using sound: PostSound) -> [PostID] { [] }
}

/// A repository that vends nothing: these tests are about the slot.
private final class SlotSilentProvider: FeedProviding, @unchecked Sendable {
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPage(afterToken token: String) async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPost(_ id: PostID) async throws -> FeedEntry { throw CancellationError() }
}
