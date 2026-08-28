import CoreModels
import MediaCore
import MediaPlayback
import Testing
import UIKit
@testable import Feed

/// A page from the moment it is warmed to the moment it is on screen showing
/// its own interface — and, above all, that every page can be REACHED.
///
/// ## Why this suite exists
///
/// The full-screen pager grew three cooperating mechanisms in one day: a panel
/// built before its cell exists, a panel mounted into a cell that does not yet
/// own the engagement, and a ceiling that refuses to page onto anything not
/// ready. Each is right on its own and each was reported broken, because they
/// share one question — where is this page's panel — and answering it in one
/// place and not another is invisible until a finger meets it.
///
/// The invariant the whole suite serves: **for any feed, paging from the first
/// post eventually reaches the last one.** A page that cannot be reached is the
/// worst failure this machinery can produce: nothing is drawn wrong, nothing is
/// logged, the gesture simply stops working.
@MainActor
struct SnapPageReadinessTests {
    private func model(_ id: String, media: URL?) -> FeedItemDisplayModel {
        FeedItemDisplayModel(
            id: PostID(id), authorID: ProfileID("a"), authorName: "A", metaText: "",
            avatarURL: nil, caption: "caption", mediaURL: media, mediaKind: .image,
            thumbnailURL: nil, audioText: nil, likeCount: 0
        )
    }

    private func media(_ id: String) -> FeedItemDisplayModel {
        model(id, media: URL(string: "https://example.test/\(id).jpg"))
    }

    private func text(_ id: String) -> FeedItemDisplayModel { model(id, media: nil) }

    /// Every page built through the same factory the app uses, so a panel the
    /// suite counts is a panel the app would have built.
    @MainActor
    private final class Panels {
        private(set) var byPost: [PostID: Int] = [:]
        func make(_ id: PostID) -> UIViewController {
            byPost[id, default: 0] += 1
            return UIViewController()
        }
        func count(_ id: String) -> Int { byPost[PostID(id)] ?? 0 }
    }

    private func feed(_ models: [FeedItemDisplayModel], panels: Panels) -> SnapFeedViewController {
        let controller = SnapFeedViewController(
            viewModel: FeedViewModel(repository: MuteProvider()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            makeCommentsPanelContent: { id in panels.make(id) }
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.seedProjection(models)
        controller.view.layoutIfNeeded()
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        return controller
    }

    /// One page of travel, the way a settled swipe performs it: move, settle,
    /// and let the page left behind finish leaving.
    ///
    /// The last step is what a unit test otherwise skips and what the app does
    /// on its own — and since a resting page keeps its interface until its last
    /// pixel has gone, skipping it would leave the slot held and every
    /// assertion about the next page wrong.
    private func advance(_ feed: SnapFeedViewController, from index: Int) {
        guard let collection = feed.view.subviews
            .compactMap({ $0 as? UICollectionView }).first else { return }
        collection.setContentOffset(
            CGPoint(x: 0, y: collection.bounds.height * CGFloat(index + 1)), animated: false
        )
        feed.scrollViewDidEndDecelerating(collection)
        feed.debugLeaveCell(at: index)
    }

    // MARK: - Reachability

    /// ⚠️ EVERY PAGE CAN BE REACHED, whatever the feed is made of.
    ///
    /// This is the property the ceiling can break and nothing else can catch: a
    /// page that is not "ready" is one the pager refuses to advance onto, so a
    /// readiness rule with a gap in it does not draw anything wrong — it stops
    /// the gesture working, silently. Reported exactly that way: two text posts
    /// in a row could not be paged through, with nothing in the trace but the
    /// hero grab correctly declining an upward drag.
    @Test(arguments: [
        ["text", "text", "text", "text"],
        ["text", "media", "text", "media"],
        ["media", "text", "text", "media"],
        ["media", "media", "text", "text"],
        ["text", "text", "media", "media"],
    ])
    func everyPageIsReachable(shape: [String]) {
        let panels = Panels()
        let models = shape.enumerated().map { index, kind in
            kind == "text" ? text("p\(index)") : media("p\(index)")
        }
        let feed = feed(models, panels: panels)

        for index in 0..<(shape.count - 1) {
            // The ceiling the PAGER uses prepares before it answers, so this
            // asks the same question the gesture does.
            #expect(feed.debugReachableCeiling() > index,
                    Comment(rawValue: "the pager refused to leave page \(index) of \(shape)"))
            // ⚠️ WHAT `willDisplay` DOES AS THE NEXT PAGE SCROLLS IN, and
            // without it this loop proves nothing about the state that
            // actually stranded a viewer.
            //
            // Mounting is what CONSUMES the warm: after it the panel is neither
            // built-ahead nor engaged, it is a preview — the third state, and
            // the one a readiness rule is most likely to forget. A test that
            // only settles never passes through it, and passes with the rule
            // broken.
            if shape[index + 1] == "text" {
                feed.debugMountRestingComments(for: PostID("p\(index + 1)"))
            }
            #expect(feed.lastReachablePage > index,
                    Comment(rawValue: "stranded on page \(index) of \(shape)"))
            advance(feed, from: index)
        }

        #expect(feed.activePostID == PostID("p\(shape.count - 1)"))
    }

    /// The ceiling exists to stop ONE thing: landing on a page that has to
    /// assemble itself in front of the viewer. A page whose panel is anywhere —
    /// built ahead, mounted as a preview, or owning the engagement — is not
    /// that page.
    @Test func aPageIsReadyWhereverItsPanelIs() {
        let panels = Panels()
        let feed = feed([media("a"), text("b")], panels: panels)

        // Built ahead by the settle.
        advance(feed, from: 0)

        #expect(feed.isPageReady(1))
        #expect(panels.count("b") == 1, "the panel was built once, not once per question")
    }

    /// ⚠️ THROUGH `willDisplay`, WHICH IS WHERE THE GATE WAS.
    ///
    /// The arriving page mounts its panel from the delegate's begin-displaying
    /// callback, and that call site carried its own "only if the slot is free"
    /// condition. Once the page being left began keeping its interface until it
    /// had gone, the slot was ALWAYS held there — so the one path that mounts a
    /// preview became unreachable from the only place that calls it.
    ///
    /// What arrived was a text page with no panel, and on a text post the
    /// caption lives inside the panel: not an undecorated page, an EMPTY one.
    /// Reported as paging that "does not work", with a trace showing the drive
    /// completing perfectly and the scroll landing exactly where it should.
    @Test func theArrivingPageMountsThroughTheDelegateEvenWhenTheSlotIsHeld() {
        let panels = Panels()
        let feed = feed([text("a"), text("b")], panels: panels)
        #expect(feed.debugRestingCommentsID == PostID("a"), "the premise: a holds the slot")

        feed.debugWillDisplayCell(at: 1)

        #expect(feed.debugPreviewRestingID == PostID("b"),
                "the arriving page mounted nothing and would render empty")
    }

    // MARK: - The screen matches the page it is on

    /// ⚠️ AN INTERFACE THAT OUTLIVES ITS PAGE MUST NOT TAKE THE PAGER WITH IT.
    ///
    /// A text page disables the pager, because its own scroll view would chain
    /// with it. That lock used to be released by a teardown — so a teardown
    /// that did not run left the feed locked on a PHOTOGRAPH for a text post
    /// two pages back. Measured exactly that way:
    /// `settled=1 engaged=post-new-07 scrollEnabled=false`, with nothing able
    /// to scroll and nothing in the trace to say why.
    ///
    /// The lock is a fact about the page on screen, so it is read off the page
    /// on screen.
    @Test func thePagerIsUnlockedByTheSettledPageNotByATeardown() {
        let panels = Panels()
        let feed = feed([text("a"), media("b")], panels: panels)
        #expect(feed.debugPagerIsLocked, "a text page locks the pager")

        advance(feed, from: 0)

        #expect(feed.debugPagerIsLocked == false,
                "the pager stayed locked on a media page for a text post that had gone")
    }

    /// And it locks again on the next text page, without anybody remembering to.
    @Test func theLockFollowsEveryPage() {
        let panels = Panels()
        let feed = feed([media("a"), text("b"), media("c")], panels: panels)
        #expect(feed.debugPagerIsLocked == false)

        advance(feed, from: 0)
        #expect(feed.debugPagerIsLocked, "a text page did not take the pager")

        advance(feed, from: 1)
        #expect(feed.debugPagerIsLocked == false)
    }

    /// A page that is still on screen keeps its interface — the reconcile
    /// releases what has GONE, not merely what is no longer active. This is
    /// what stops the page being left from emptying while the settle animates.
    @Test func aVisiblePageKeepsItsInterfaceThroughTheSettle() {
        let panels = Panels()
        let feed = feed([text("a"), text("b")], panels: panels)

        // Settle on b without telling the screen that a has finished leaving.
        guard let collection = feed.view.subviews
            .compactMap({ $0 as? UICollectionView }).first else { return }
        collection.setContentOffset(
            CGPoint(x: 0, y: collection.bounds.height), animated: false
        )
        feed.scrollViewDidEndDecelerating(collection)

        #expect(feed.debugRestingCommentsID == PostID("a"),
                "the page being left was emptied while it was still on screen")
    }

    // MARK: - The display, page by page

    /// A text page owns its interface the moment it is the settled page.
    @Test func aSettledTextPageOwnsItsInterface() {
        let panels = Panels()
        let feed = feed([text("a"), media("b")], panels: panels)

        #expect(feed.debugRestingCommentsID == PostID("a"))
        #expect(panels.count("a") == 1)
    }

    /// And a media page owns no RESTING interface — arriving is not engaging.
    ///
    /// It does get a panel built, and that is a different mechanism: the
    /// tap-to-comments warm, which exists so pressing the count is instant. The
    /// distinction matters because the two share a field, and reading a warm as
    /// an engagement is what made a text page arrive black.
    @Test func aSettledMediaPageOwnsNoRestingInterface() {
        let panels = Panels()
        let feed = feed([media("a"), text("b")], panels: panels)

        #expect(feed.debugRestingCommentsID == nil)
    }

    /// ⚠️ THE HANDOVER, END TO END: the page arriving shows its panel while the
    /// page leaving still owns the slot, and the ownership moves only when the
    /// leaving page has actually left.
    ///
    /// Three states in order, each of which was a defect on its own: the
    /// arriving page black (no preview), the leaving page emptied at the settle
    /// (torn down too early), and the arriving page never promoted (owning
    /// nothing, so its pager lock never applied).
    @Test func theInterfaceIsHandedOverInThatOrder() {
        let panels = Panels()
        let feed = feed([text("a"), text("b")], panels: panels)
        #expect(feed.debugRestingCommentsID == PostID("a"))

        // As it scrolls in, while the page being left still owns the slot.
        feed.debugMountRestingComments(for: PostID("b"))
        #expect(feed.debugPreviewRestingID == PostID("b"), "the arriving page had nothing to show")
        #expect(feed.debugRestingCommentsID == PostID("a"), "the leaving page lost its interface")

        // The settle alone must NOT move it: the page being left is still on
        // screen and still using it.
        advance(feed, from: 0)
        #expect(feed.debugRestingCommentsID == PostID("b"), "ownership never moved")
        #expect(feed.debugPreviewRestingID == nil)
        #expect(panels.count("b") == 1, "the handover built a second panel")
    }

    /// Nothing is built twice across a whole run — the warm, the preview and
    /// the engagement are three states of ONE panel, not three panels.
    @Test func onePanelPerTextPageAcrossAWholeRun() {
        let panels = Panels()
        let feed = feed([text("a"), text("b"), text("c")], panels: panels)

        advance(feed, from: 0)
        advance(feed, from: 1)

        #expect(panels.count("a") == 1)
        #expect(panels.count("b") == 1)
        #expect(panels.count("c") == 1)
    }

    /// A media page in the middle does not cost a panel, and does not stop the
    /// text page after it from getting one.
    @Test func aMediaPageBetweenTwoTextPagesCostsNothing() {
        let panels = Panels()
        let feed = feed([text("a"), media("b"), text("c")], panels: panels)

        advance(feed, from: 0)

        #expect(panels.count("b") == 0, "a media page was given a resting panel")
        #expect(feed.isPageReady(2), "the text page after it was never warmed")
    }
}

/// Vends nothing: these are about what the screen does with what it has.
private final class MuteProvider: FeedProviding, @unchecked Sendable {
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
