import CoreModels
import LaunchArguments
import QuartzCore
import UIKit

/// What an opening request asks of the arriving screen (#2514): its view, to
/// lay out before the push, the pages and the pager a realized cell is found
/// in, and the comments it opens.
///
/// A view controller: the request is laid out and engaged on its view.
@MainActor
protocol SnapOpeningRequestsHost: UIViewController {
    var orderedIDs: [PostID] { get }
    var collectionView: UICollectionView! { get }
    var commentsCoordinator: SnapCommentsCoordinator { get }
    var commentsEngagedID: PostID? { get }
    var commentsSheet: SnapCommentsSheetSession? { get }
}

/// The one-shot instructions an opener gives the full-screen feed it pushes
/// (#2514): open a carousel on a page other than its first, open a post with
/// its comments already engaged — each applied to a realized cell at once if
/// there is one, else kept until the first configure or the landing, and
/// cleared only once it has been used.
///
/// ⚠️ SYNCHRONOUS WITH ITS SCREEN: every entry point runs in the caller's
/// turn, where the screen called it before — the builder's push, the cell
/// provider's configure, the appearance and the landing.
@MainActor
final class SnapOpeningRequests {
    private unowned let host: any SnapOpeningRequestsHost

    init(host: any SnapOpeningRequestsHost) {
        self.host = host
    }

    /// The post whose carousel still owes an opening page — see
    /// `openMediaPage(_:for:)`. Stored on the class because an extension
    /// cannot hold state, which is where the seam it belongs to lives.
    private var pendingMediaPage: (id: PostID, page: Int)?
    /// The post that must open ALREADY SHOWING its comments — see
    /// `openComments(for:)`.
    private(set) var pendingCommentsID: PostID?

    /// Opens one post's carousel on a page other than its first.
    ///
    /// A ONE-SHOT instruction rather than a stored preference, and the
    /// distinction matters on a feed the viewer scrolls: it applies to the
    /// first configure of that post and is then forgotten, so paging back to
    /// the post later — or a cell recycling onto it — starts where a fresh open
    /// starts. A remembered page would make the same post open differently
    /// depending on history nobody can see.
    func openMediaPage(_ page: Int, for id: PostID) {
        pendingMediaPage = (id, page)
        // ⚠️ AND APPLIED NOW IF THERE IS ANYTHING TO APPLY IT TO.
        //
        // The pending value is consumed by the data source's cell provider,
        // which only runs when a cell is CONFIGURED. That covers the first
        // open and nothing else: this screen is reused, so opening the same
        // post again reaches a cell that is already built and still sitting on
        // the page the viewer left it on. The instruction was then recorded and
        // never read.
        //
        // What that looked like, measured with the page traced at activation:
        // `card asked page=9` immediately followed by `cell activate page=4
        // url=trailer.mp4`. The page displayed page 9 while warming page FOUR's
        // clip — so it arrived showing page 9's poster, and the dismissal
        // donated the surface it had warmed, sending the card home carrying the
        // PREVIOUS clip. Reported precisely: "B arrives on the thumbnail, and
        // the dismiss shows A".
        //
        // Cleared on success so the configure path cannot apply it a second
        // time, and left pending when the cell is not realized yet — which is
        // the first-open case the provider already handles.
        guard let index = host.orderedIDs.firstIndex(of: id),
              let cell = host.collectionView.cellForItem(at: IndexPath(item: index, section: 0))
                  as? SnapFeedCell
        else { return }
        cell.showMediaPage(page)
        pendingMediaPage = nil
    }

    /// Opens a post with its comments already engaged.
    ///
    /// A ONE-SHOT instruction, on the same terms as `openMediaPage(_:for:)` and
    /// for the same reason: the feed is scrolled, and a remembered preference
    /// would make paging back to this post — or a cell recycling onto it —
    /// behave differently from a fresh open, on history nobody can see.
    ///
    /// ⚠️ APPLIED ON LANDING, never at push time. The engagement is ~115ms of
    /// layout, and the flight is the one stretch of this screen's life where
    /// that cost is visible: `prewarmComments` refuses to run during a
    /// transition for exactly this reason, having measured the present leg's
    /// first layout go from 36–64ms to 139–145ms. So the post arrives, and then
    /// its comments come up — which is also the honest reading of the gesture,
    /// since the card the viewer pressed is what the flight is carrying.
    ///
    /// `rect` fed the masked opening of the first comments space; the sheet
    /// rises on its own, and it is ignored (#2087).
    func openComments(for id: PostID, revealingFrom rect: CGRect? = nil) {
        pendingCommentsID = id
        // ⚠️ NOW, IF THERE IS ANYTHING TO DO IT TO — before the push, not after
        // the landing.
        //
        // Applied on landing, the viewer watched the post arrive in its ordinary
        // layout and THEN rearrange itself into the thread: two screens for one
        // press. The engagement has to be the state the page is already in when
        // it becomes visible, which means it has to happen before the flight
        // starts, because during the flight is the one window this screen
        // refuses to spend layout in.
        //
        // The cost is real and it moves rather than disappears: the delay now
        // sits between the finger lifting and the card leaving, where it reads
        // as latency, instead of inside the animation, where it reads as jank.
        // Of the two that is the one to take — and there is nothing to animate
        // yet, so the engagement is applied UNANIMATED and simply is the layout
        // the page opens in.
        host.loadViewIfNeeded()
        // One layout pass, to give the request a cell to engage.
        //
        // ⚠️ WHERE THIS OPENING'S COST ACTUALLY IS, because two plausible
        // answers were measured and are both wrong.
        //
        // Filmed against the same post opened the ordinary way: 350ms
        // tap-to-settled, against 650–800ms here. The extra is NOT this call
        // (57ms) and NOT an unresolved layout — a second `layoutIfNeeded` after
        // the engagement measures 0.02ms, so `presentComments` has already
        // resolved the tree. It is a stall of ~270–300ms at the LANDING, which
        // shows up as the flight card sitting at full size for a quarter of a
        // second before the thread appears under it.
        //
        // `syncEngagementAfterAppearance` is where that work is: at
        // `viewDidAppear` it re-seats the composer and re-materializes its
        // frost, saying in as many words that the window guard makes every
        // earlier call a no-op and "the didAppear pass the one that lands".
        // Moving the header frost AND the composer's into
        // `zoomTransitionWillBegin` — the first moment there is a window and
        // the last one where the card still hides everything — did not move the
        // number, so the cost is not the materials alone. Both attempts were
        // reverted rather than kept on a story.
        host.view.layoutIfNeeded()
        #if DEBUG
        let __engaged = CACurrentMediaTime()
        #endif
        applyPendingComments(animated: false)
        #if DEBUG
        if LaunchArgument.engageProfile.isPassed() {
            print(String(format: "[engage] pre-push engage %6.2f ms",
                         (CACurrentMediaTime() - __engaged) * 1000))
        }
        #endif
    }

    /// Engages the comments a card asked for, once there is a page to engage
    /// them on. Reading the request clears it, so a dismissal and a second open
    /// start from nothing.
    ///
    /// Silent when the post has no cell yet — a feed pushed cold has no pages
    /// until its first render, and the landing seam is what picks the request up
    /// then. Which is why the request is only cleared once it is USED.
    func applyPendingComments(animated: Bool) {
        guard let id = pendingCommentsID else { return }
        host.commentsCoordinator.presentComments(for: id, animated: animated)
        // ⚠️ CONSUMED ONLY IF IT LANDED, and the difference is a whole defect.
        //
        // `presentComments` needs a REALIZED CELL, not just a row in the data
        // source — and before the push this screen has been laid out at
        // whatever size it was born with, so on the first open of a process
        // there is often no cell yet. The request was cleared anyway, the
        // engagement bailed silently, and the post opened in its ordinary
        // layout. The SECOND open worked, because the feed controller is
        // reused and by then has both.
        //
        // "I asked" and "it happened" are different facts, and only the second
        // one may clear a one-shot.
        //
        // ⚠️ THE SHEET TOO (#2087): a media post's comments open in a sheet,
        // which never takes `commentsEngagedID`; the request stayed armed,
        // and the next appearance or landing opened the sheet again after the
        // viewer had closed it.
        if host.commentsEngagedID == id || host.commentsSheet?.postID == id { pendingCommentsID = nil }
    }

    /// Takes the pending page for `id`, if there is one. Reading it clears it —
    /// see `openMediaPage`.
    func consumeInitialMediaPage(for id: PostID) -> Int? {
        guard let pending = pendingMediaPage, pending.id == id else { return nil }
        pendingMediaPage = nil
        return pending.page
    }
}
