import CoreModels
import FeedInterface
import MediaCore
import Testing
import UIKit
@testable import Feed

/// The composer's rail slot wears the post's sound (#671) and answers as the
/// page's sound bubble does (#680): a TAP toggles the feed's sound, a LONG
/// PRESS opens the sound sheet. On a text page the slot is the only place the
/// sound lives, so a slot that drew the cover and did nothing was the bug.
@MainActor
struct SnapComposerSoundSlotTests {
    private typealias Layout = SnapActionColumnLayoutTests
    private static let face = SnapSoundFace(coverURL: nil, isAvailable: true, isMuted: false)

    /// A tap on the slot is the host's action, whatever the slot wears.
    @Test func aTapOnTheSoundSlotIsTheHostsAction() {
        let bar = CommentsInputBar()
        bar.railFace = .sound(Self.face)
        var taps = 0
        bar.onRailAction = { taps += 1 }
        bar.debugRailButton.sendActions(for: .primaryActionTriggered)
        #expect(taps == 1)
    }

    /// A hold reaches the host only from a sound the post plays: a greyed
    /// sound (a clip with no audio) and the other faces ignore it.
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
        bar.railFace = .sound(SnapSoundFace(coverURL: nil, isAvailable: false, isMuted: false))
        bar.debugHoldRail()
        #expect(holds == 1, "a sound the post does not play opened the sheet")
        bar.railFace = .pin(isPinned: false)
        bar.debugHoldRail()
        #expect(holds == 1, "the pin opened the sound sheet")
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

    /// ⚠️ THE TEXT PAGE (#680): the snap feed wires its panel's slot to the
    /// feed's own sound — a tap flips `FeedSound` — and to the sound sheet.
    @Test func aTextPagesSlotTogglesTheFeedsSound() throws {
        let feed = SnapFeedViewController(
            viewModel: FeedViewModel(repository: SlotSilentProvider()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            soundProvider: SlotSoundProvider()
        )
        feed.loadViewIfNeeded()
        feed.seedProjection([
            FeedItemDisplayModel(
                id: PostID("p"), authorID: ProfileID("a"), authorName: "Ava", metaText: "",
                avatarURL: nil, caption: "A text page", mediaURL: nil, mediaKind: .image,
                thumbnailURL: nil, audioText: nil, likeCount: 3
            )
        ])
        let (panel, window) = Layout.engagedPanel()
        defer { window.isHidden = true }
        feed.applySoundRail(to: panel)
        let bar = try Layout.composerColumn(in: panel.view, space: window).bar
        #expect(bar.debugRailSymbol == CommentsInputBar.soundRailSymbol, "the text page's slot does not wear its sound")
        #expect(bar.onRailLongPress != nil, "the hold is not wired to the sound sheet")

        let before = FeedSound.isOn
        bar.debugRailButton.sendActions(for: .primaryActionTriggered)
        #expect(FeedSound.isOn != before, "the slot's tap did not toggle the sound")
        bar.debugRailButton.sendActions(for: .primaryActionTriggered)
        #expect(FeedSound.isOn == before)
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

        let file = SnapSoundFace(coverURL: url, isAvailable: true, isMuted: false)
        #expect(file.cachedCover != nil)
        #expect(file.disc(side: 36) != nil)

        let remote = SnapSoundFace(
            coverURL: URL(string: "https://example.test/\(UUID().uuidString).jpg"),
            isAvailable: true, isMuted: false
        )
        #expect(remote.cachedCover == nil, "a remote cover drew before its fetch")
    }
}

private struct SlotSoundProvider: PostSoundProviding {
    func sound(forPost postID: PostID, clip: URL?) -> PostSound? {
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
