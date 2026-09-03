import CoreModels
import MediaCore
import MediaPlayback
import Testing
import UIKit
@testable import Feed

/// **A FEED PUSHED BEFORE ITS CORPUS ARRIVES SHOWS THE SCREEN IT IS OPENING
/// ONTO, in the state that screen is actually in.**
///
/// The ground fix stopped the window being black; it was still empty, because
/// with zero items there are no cells and `.loading` drew nothing at all.
/// Filmed as ~930ms of blank grey on the FIRST selection of a map pin and none
/// on the second — the first being what fills the cache the synchronous seed
/// reads.
///
/// ⚠️ IT IS THE REAL PANEL, not a drawing of one. Built from the same factory
/// the resting page uses, and handed to the cell when the post lands, so what
/// the viewer watches load is the thing that finishes loading. It also makes
/// dishonesty impossible: a `PostID` is the only thing the factory is given, so
/// there is no channel through which an author, a handle or a caption could be
/// invented — and the map pin carries none of them anyway.
@MainActor
struct SnapFeedLoadingPageTests {
    private final class PanelSpy {
        var asked: [PostID] = []
    }

    private func model(_ id: String, media: URL?) -> FeedItemDisplayModel {
        FeedItemDisplayModel(
            id: PostID(id), authorID: ProfileID("a"), authorName: "Ava", metaText: "",
            avatarURL: nil, caption: "caption", mediaURL: media, mediaKind: .image,
            thumbnailURL: nil, audioText: nil, likeCount: 0
        )
    }

    private func feed(_ spy: PanelSpy) -> SnapFeedViewController {
        let controller = SnapFeedViewController(
            viewModel: FeedViewModel(repository: MuteFeed()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            makeCommentsPanelContent: { id in
                spy.asked.append(id)
                // Deliberately BARE: nothing in the production path may force
                // cast this to `PostDetailViewController`.
                let panel = UIViewController()
                panel.view.backgroundColor = .systemPink
                return panel
            }
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.layoutIfNeeded()
        return controller
    }

    private func collection(_ feed: SnapFeedViewController) -> UICollectionView? {
        feed.view.subviews.compactMap { $0 as? UICollectionView }.first
    }

    /// Arming records; only `presentLoadingPage` draws. That split is what keeps
    /// a media hero — which never reaches the text-reveal installer — from
    /// being promised comment bones.
    @Test func armingAloneDrawsNothing() {
        let spy = PanelSpy()
        let feed = feed(spy)
        feed.armLoadingPage(for: PostID("a"))

        #expect(feed.debugShowsLoadingPage == false)
        #expect(spy.asked.isEmpty)
    }

    /// The window's first frame: the arrival screen, over the lent ground —
    /// which must still be the lent ground. This is the regression guard on the
    /// empty-ground fix: the loading page ADDS to it, never replaces it.
    @Test func aTextRevealDrawsTheArrivalScreenOverTheLentGround() throws {
        let spy = PanelSpy()
        let feed = feed(spy)
        feed.setEmptyGround(.secondarySystemBackground)
        feed.armLoadingPage(for: PostID("a"))
        feed.presentLoadingPage()

        let panel = try #require(feed.debugLoadingPanel)
        #expect(panel.view.superview === feed.view)
        #expect(feed.view.backgroundColor == .secondarySystemBackground)
        #expect(try #require(collection(feed)).backgroundColor == .secondarySystemBackground)
    }

    /// ⚠️ NOTHING HERE MAY MAKE THE FEED LOOK NON-EMPTY.
    /// `zoomDestinationContentIsReady` is `!orderedIDs.isEmpty` and is read by
    /// the hero's readiness gate; a loading page that added a row would make a
    /// landing believe its content had arrived.
    @Test func theLoadingPageAddsNoPages() throws {
        let spy = PanelSpy()
        let feed = feed(spy)
        feed.armLoadingPage(for: PostID("a"))
        feed.presentLoadingPage()

        #expect(feed.zoomDestinationContentIsReady == false)
        // ⚠️ SECTIONS, not items. No snapshot has been applied, so asking for
        // section 0's count raises — which is itself the statement being made:
        // the loading page adds nothing to the data source at all.
        #expect(try #require(collection(feed)).numberOfSections == 0)
    }

    /// The honesty test: a PostID is the whole of what the loading page is
    /// given, so there is no way for it to show a name it does not have.
    @Test func theFactoryIsAskedForTheArmedPostAndNothingElse() {
        let spy = PanelSpy()
        let feed = feed(spy)
        feed.armLoadingPage(for: PostID("a"))
        feed.presentLoadingPage()

        #expect(spy.asked == [PostID("a")])
    }

    /// The handover: the SAME object is re-parented rather than destroyed and
    /// rebuilt, which is why there is never a frame of neither.
    @Test func aTextHeadTakesThePanelOverInsteadOfFadingIt() throws {
        let spy = PanelSpy()
        let feed = feed(spy)
        feed.armLoadingPage(for: PostID("a"))
        feed.presentLoadingPage()
        let panel = try #require(feed.debugLoadingPanel)

        feed.seedProjection([model("a", media: nil)])

        #expect(feed.debugShowsLoadingPage == false)
        #expect(feed.debugPrewarmedRestingID == PostID("a"))
        // Still alive — parked for the cell rather than torn down.
        #expect(panel.parent == nil || panel.parent === feed)
    }

    /// A comment skeleton is not a photograph's loading state, and the
    /// `mediaURL == nil` test in the retire is what keeps that honest.
    @Test func aMediaHeadRetiresTheLoadingPageWithoutHandingItOver() throws {
        let spy = PanelSpy()
        let feed = feed(spy)
        feed.setEmptyGround(.secondarySystemBackground)
        feed.armLoadingPage(for: PostID("a"))
        feed.presentLoadingPage()

        feed.seedProjection([model("a", media: URL(string: "https://example.test/a.jpg"))])

        #expect(feed.debugShowsLoadingPage == false)
        #expect(feed.debugPrewarmedRestingID == nil)
        #expect(feed.view.backgroundColor == .black)
    }

    /// ⚠️ RETIRED ON ANY RENDER, not on the one carrying the armed post.
    ///
    /// `.empty` and `.failed` both render with zero items, so "wait for the
    /// post" would leave the skeletons sitting over the status label for ever.
    /// Driven here with a corpus that resolves to a DIFFERENT post, which is
    /// the same shape of answer and the one a test can produce: the seed is
    /// additive and ignores an empty array, so it cannot stand in for an empty
    /// render — that one arrives from the view model's own first load.
    @Test func aRenderThatIsNotTheArmedPostStillRetiresTheLoadingPage() {
        let spy = PanelSpy()
        let feed = feed(spy)
        feed.armLoadingPage(for: PostID("a"))
        feed.presentLoadingPage()
        #expect(feed.debugShowsLoadingPage)

        feed.seedProjection([model("b", media: nil)])

        #expect(feed.debugShowsLoadingPage == false)
        // Not handed over either — it was standing in for a different post.
        #expect(feed.debugPrewarmedRestingID == nil)
    }

    /// A second install is a no-op: the window is drawn once.
    @Test func theLoadingPageIsInstalledOnlyOnce() {
        let spy = PanelSpy()
        let feed = feed(spy)
        feed.armLoadingPage(for: PostID("a"))
        feed.presentLoadingPage()
        feed.presentLoadingPage()

        #expect(spy.asked == [PostID("a")])
    }
}

/// Answers nothing, so the screen under test is the only thing deciding what is
/// drawn.
private final class MuteFeed: FeedProviding, @unchecked Sendable {
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPage(afterToken token: String) async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPost(_ id: PostID) async throws -> FeedEntry {
        throw FeedError.transport(message: "mute")
    }
}
