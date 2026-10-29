import CoreModels
import CoreStorage
import DesignSystem
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// FEED SPEAKS IN ROLES (#1883): every haptic in Feed names the moment it
/// plays (`Haptics.play`), and turning a state off is silent (#1881).
@MainActor
struct FeedHapticRolesTests {
    /// What `body` played, on a recorder whose clock moves a second between
    /// two plays when `spaced` — so pacing never hides a crossing.
    private func recorded(spaced: Bool = false, _ body: (_ tick: () -> Void) -> Void) -> [Haptic] {
        let recorder = HapticRecorder()
        var now: TimeInterval = 0
        recorder.clock = { now }
        Haptics.$recorder.withValue(recorder) {
            body { if spaced { now += 1 } }
        }
        return recorder.played
    }

    // MARK: - The author pill

    /// The pill's hold is a hold recognised, felt once.
    @Test func theAuthorPillsHoldIsHeldOnce() {
        let pill = SnapAuthorIdentityView()
        pill.setPerson(
            id: ProfileID("prof-ada"), name: "Ada", meta: "@ada", avatarURL: nil,
            pipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        pill.onAuthorLongPressed = { _ in }
        let played = recorded { _ in pill.debugLongPress() }
        #expect(played == [.held])
    }

    // MARK: - The sound

    private final class EmptyFeed: FeedProviding, @unchecked Sendable {
        func cachedFirstPage() async -> [FeedEntry]? { nil }
        func loadFirstPage() async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
        func loadPage(afterToken token: String) async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
        func loadPost(_ id: PostID) async throws -> FeedEntry { throw URLError(.fileDoesNotExist) }
    }

    /// Every mute and unmute by a hold is a hold recognised.
    @Test func theSoundHoldIsHeld() {
        let feed = SnapFeedViewController(
            viewModel: FeedViewModel(repository: EmptyFeed()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        feed.loadViewIfNeeded()
        let played = recorded(spaced: true) { tick in
            feed.debugToggleSound()
            tick()
            feed.debugToggleSound()
        }
        #expect(played == [.held, .held])
    }

    // MARK: - The page bar

    private func pageBar(pages: Int) -> SnapMediaPageBarView {
        let view = SnapMediaPageBarView(frame: CGRect(x: 0, y: 0, width: 370, height: SnapMediaPageBarView.thickness))
        view.configure(count: pages, current: 0)
        view.layoutIfNeeded()
        return view
    }

    /// One `step` per page crossed under the finger; none for a page the
    /// host moved to.
    @Test func thePageBarStepsOncePerPageCrossedAndNeverForAProgrammaticMove() {
        let view = pageBar(pages: 4)
        let slot = view.browseSlotWidth
        let played = recorded(spaced: true) { tick in
            view.debugScrub(.began, atX: slot * 0.5)
            view.debugScrub(.changed, atX: slot * 1.5)
            tick()
            view.debugScrub(.changed, atX: slot * 1.6)
            tick()
            view.debugScrub(.changed, atX: slot * 2.5)
            tick()
            view.debugScrub(.changed, atX: slot * 3.5)
            view.debugScrub(.ended, atX: slot * 3.5)
        }
        #expect(played == [.step, .step, .step])

        let moved = recorded { _ in
            view.setPosition(1)
            view.setPosition(3)
        }
        #expect(moved.isEmpty, "a programmatic move played \(moved)")
    }

    // MARK: - The shelf's pull

    /// `armed` once per crossing under the finger: not again while held
    /// past, again after coming back under, never without the finger.
    @Test func theShelfsPullIsArmedOncePerCrossing() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let shelf = PostShelfSection(imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()), videoPlayback: nil)
        shelf.frame = CGRect(x: 0, y: 0, width: 402, height: 800)
        window.addSubview(shelf)
        window.isHidden = false
        defer { window.isHidden = true }
        shelf.onViewAll = {}
        shelf.hasMore = true
        _ = shelf.render((0..<6).map { post("m\($0)", kind: .photo) })
        shelf.layoutIfNeeded()
        let row = shelf.mediaView
        row.layoutIfNeeded()
        let end = row.contentSize.width + row.adjustedContentInset.right - row.bounds.width
        func pull(_ distance: CGFloat, tracking: Bool = true) {
            row.contentOffset.x = end + distance
            shelf.followEndPull(row, isTracking: tracking)
        }
        let threshold = PostShelfSection.endPullThreshold
        // A second apart each: the player's pacing never hides a crossing.
        let played = recorded(spaced: true) { tick in
            for (distance, tracking) in [
                (threshold - 10, true), (threshold + 5, true), (threshold + 20, true),
                (threshold - 10, true), (threshold + 5, true), (0, true), (threshold + 5, false),
            ] {
                pull(distance, tracking: tracking)
                tick()
            }
        }
        #expect(played == [.armed, .armed], "the pull played \(played)")
    }

    // MARK: - Bookmarks

    private func post(_ id: String, kind: GalleryPost.Kind) -> GalleryPost {
        GalleryPost(
            id: PostID(id), kind: kind, isRepost: false,
            thumbnailURL: kind == .text ? nil : URL(string: "https://example.com/\(id).jpg"),
            caption: "caption \(id)", publishedAtMS: 1,
            authorID: ProfileID("bo"), authorName: "Bo", authorHandle: "bo",
            reactionCount: 3, commentCount: 1
        )
    }

    /// Saving plays `toggleOn`; unsaving plays nothing.
    @Test func bookmarkingPlaysToggleOnAndRemovingItPlaysNothing() throws {
        let bookmarks = PostBookmarkStore(
            defaults: UserDefaults(suiteName: "feed-haptics-\(UUID().uuidString)")!,
            scope: StorageScope(owner: .member(account: "acc-1", profile: "prof-1"))
        )
        let menu = PostMenuRows(bookmarks: bookmarks)
        let anchor = UIView()
        func save() throws {
            let rows = menu.rows(for: post("p", kind: .photo), anchor: anchor)
            guard case .save(_, let perform)? = rows.first else {
                Issue.record("no Save row first")
                return
            }
            perform()
        }
        let saving = try recordedThrowing { try save() }
        #expect(saving == [.toggleOn])
        #expect(bookmarks.isSaved("p"))
        let unsaving = try recordedThrowing { try save() }
        #expect(unsaving.isEmpty, "unsaving played \(unsaving)")
        #expect(!bookmarks.isSaved("p"))
    }

    private func recordedThrowing(_ body: () throws -> Void) throws -> [Haptic] {
        let recorder = HapticRecorder()
        try Haptics.$recorder.withValue(recorder) { try body() }
        return recorder.played
    }
}
