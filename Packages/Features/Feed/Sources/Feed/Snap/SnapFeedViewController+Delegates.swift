import CoreImage
import CoreStorage
import MediaCore
import CoreModels
import CoreNavigation
import Transitions
import DesignSystem
import EmoteKit
import EntityStore
import FeedInterface
import MediaPlayback
import MediaUI
import PostGrid
import PostSurfaces
import ShareSheet
import ThreadKit
import UIKit
import VoiceKitUI
import LaunchArguments

// MARK: - Delegates

extension SnapFeedViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        // Before any activation below: a page learnt unavailable (#1409)
        // after its cell was configured — prefetched, off screen — is told
        // now, so nothing of it starts.
        if let snapCell = cell as? SnapFeedCell, let id = snapCell.representedPostID {
            snapCell.setPostUnavailable(unavailablePostIDs.contains(id))
        }
        // A page coming on while the side list is open wears its pose (#1509).
        (cell as? SnapFeedCell)?.setSideListOverlayOffset(sideListSession.sideListOverlayOffset)
        // …and the content freeze's state, frozen or not (#1738).
        if let snapCell = cell as? SnapFeedCell {
            carouselFreeze.display(snapCell) { $0.setCarouselScrollEnabled($1) }
        }
        viewModel.willDisplayItem(at: indexPath.item)
        // Recompute the active index (a new page may have become active), then —
        // crucially — activate THIS cell if it's the active one. The dispatcher
        // records the active index the instant a scroll settles or content
        // loads, which can be before the cell exists; without this net that
        // activation would be lost, since the index never changes again.
        updateActiveItem()
        // Stamp the flight deferral BEFORE any activation on this path. There
        // are two activation sites — the settle-quantized one in `apply` and
        // this net for cells that did not exist at settle time — and a present
        // leg always takes THIS one, because the cell is realized by the very
        // layout pass the presentation triggers. Stamping only in `apply` left
        // the flag false exactly when it mattered.
        (cell as? SnapFeedCell)?.defersPlaybackForFlight = flight.defersPlaybackForStagingFlight
        if let snapCell = cell as? SnapFeedCell { zoomDestination.stampFlightMediaStart(on: snapCell) }
        // The same net, for the picture: a page can be handed the screen while
        // it is still being realized, and the hand-over reaches nothing. The
        // page that owns the viewport is a fact about the SCROLL, so it is
        // re-stated to every cell as it appears.
        (cell as? SnapFeedCell)?.clipStart.setOwnsViewport(playbackOwner == indexPath.item)
        // And the sound follows the picture's owner, for the same reason.
        if playbackOwner == indexPath.item { soundPlayback.refreshAudibleSurface(ownerCell: cell as? SnapFeedCell) }
        if lifecycle.activeIndex == indexPath.item {
            // ⚠️ THE HOLD, TOO, IS STAMPED HERE — `zoomTransitionWillBegin`
            // held `activeSnapCell`, and on a finger's tap that cell does not
            // exist yet (traced 25 September 2026: `setActive Y … held=N
            // window=N`, then a pre-fill of nine bubbles into a band that
            // was not in any window). Unheld, the ticker laid its train
            // during the flight, and the page landed on an empty band with
            // bubbles arriving from the right and no fade. Only the page
            // that will be active is held: a neighbour realised during the
            // flight would never be released.
            if flight.isAwaitingZoomPresentation { (cell as? SnapFeedCell)?.setChromeHeldForFlight(true) }
            (cell as? SnapCellLifecycle)?.willBecomeActive()
        }
        // A text page's resting interface PRE-RENDERS on visibility (not
        // the settle-quantized active seam): the instant its cell begins
        // displaying — while it is still scrolling in — its full engaged
        // layout is mounted, so it slides into the viewport already
        // formed instead of popping in at rest. This is the same
        // visibility doctrine the ticker/subtitle surfaces below follow;
        // the pager lock alone waits for settle (`lockRestingEngagement`).
        // Slot-guarded (one engagement at a time), model presence REQUIRED
        // (a missing model reads as "unknown", never "text-only").
        if let snapCell = cell as? SnapFeedCell, orderedIDs.indices.contains(indexPath.item) {
            let id = orderedIDs[indexPath.item]
            // ⚠️ NOT GATED ON THE SLOT BEING FREE, and that gate is what made
            // the arriving page blank.
            //
            // It reads as a guard against mounting twice, and it was — until
            // the page being left began keeping its interface until its last
            // pixel has gone. From then on the slot is ALWAYS held while the
            // next page scrolls in, so this declined every time and the one
            // path that mounts a preview was unreachable from the only place
            // that calls it.
            //
            // What arrives is a text page with no panel: on a text post the
            // caption lives INSIDE the panel, so the page is not merely
            // undecorated, it is empty — white, no caption, no comments, just
            // chrome. `presentRestingComments` makes this decision properly:
            // engagement if the slot is free, preview if it is not.
            if let model = modelsByID[id], model.mediaURL == nil {
                if Self.defersRestingCommentsForFlight, flight.isAwaitingAnyFlight,
                   commentsEngagedID == nil, commentsContentVC == nil {
                    commentsCoordinator.installRestingPlaceholder(for: id, model: model, host: snapCell)
                } else {
                    commentsCoordinator.presentRestingComments(for: id, host: snapCell)
                }
            }
            // PHASE 2, when this cell is ALREADY the active page.
            //
            // The settle path normally applies the lock, and normally it
            // runs after the cell exists. A programmatic jump inverts that:
            // `-snap-start-index` scrolls and settles in one turn, so the
            // activation lands before the layout has realized the cell, the
            // settle path finds nothing to mount, and the pre-render above
            // arrives here afterwards — with no further activation coming,
            // because the dispatcher is already on this page. The page kept
            // the RESTING chrome for its whole life: no sort pill, and a
            // caption cell measured under bars it no longer had.
            //
            // The active-index test is what keeps this phase 2 and not a
            // second pre-render: a cell scrolling in normally is not the
            // active page yet, so it falls through to the settle path
            // exactly as before, and the pager is never locked mid-scroll.
            // (Same test the `willBecomeActive` call above uses.)
            if lifecycle.activeIndex == indexPath.item,
               commentsEngagedID == id, commentsEngagementIsResting {
                commentsCoordinator.lockRestingEngagement()
            }
            // And a MEDIA page warms its comments panel here for the same
            // reason the lock above lands here: on a programmatic jump the
            // settle runs before the layout has realized the cell, so the
            // settle's own warm found nothing to host. Gated on being the
            // ACTIVE page, so a page merely scrolling past never pays for a
            // panel it will not open.
            if lifecycle.activeIndex == indexPath.item,
               let model = modelsByID[id], model.mediaURL != nil {
                commentsCoordinator.prewarmComments(for: id, host: snapCell)
            }
        }
        // Re-pull the cached streams BEFORE raising the visibility gate: a
        // cell configured while the prefetch load was still in flight
        // pulled `.empty` at dequeue, and the async push only reaches
        // visible cells — this cell missed it. Synchronous on a cache hit,
        // so the surfaces own their content when activation lands and the
        // subtitle zone takes its INSTANT entrance (riding the swipe like
        // static chrome) instead of the content-arrival fade after settle.
        // (`updateCommentStreams` no-ops on identical content; still-
        // uncached posts stay empty here and fade in when the push lands.)
        if let snapCell = cell as? SnapFeedCell, orderedIDs.indices.contains(indexPath.item) {
            snapCell.updateCommentStreams(viewModel.commentStreams(for: orderedIDs[indexPath.item]))
        }
        // Both comment surfaces render on VISIBILITY, not on the settle-
        // quantized active seam: a page dragged partway in must already
        // show its band flowing and its subtitle pill pinned, not pop them
        // in at rest. (Video stays settle-gated — an AVPlayer per
        // half-visible page is real cost; text layers aren't.)
        (cell as? SnapFeedCell)?.setTickerStreaming(true)
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        // Paged away: a voice post's voice stops where it is (#2207).
        if let snapCell = cell as? SnapFeedCell, let id = snapCell.representedPostID {
            VoicePlaybackHub.shared.stop(VoicePosts.playbackID(id))
        }
        // Belt-and-suspenders release: a cell scrolled fully off is never active,
        // and this guarantees the resign even if it's recycled before a settle.
        // Fully off screen: the loan goes back, because the grid behind is
        // waiting for it and nothing here is going to draw again.
        // ⚠️ EXCEPT the post on show's page recycled by the items' swap
        // (#1580): its clip goes on, for the page that shows the post next to
        // adopt (`handOverReorderedPlayback`).
        if isReplacingItems, let snapCell = cell as? SnapFeedCell, let held = reorderHeld,
           snapCell.representedPostID == held.id {
            snapCell.resignKeepingPlayback()
            // Its band and pill keep running through the swap (#1798).
            reorderHeldCell = snapCell
        } else {
            (cell as? SnapCellLifecycle)?.didResignActive(releasingPlayback: true)
            // The resign above no-ops for a cell that was displayed but never
            // became active (a swiped-past page); its ticker must still stop.
            (cell as? SnapFeedCell)?.setTickerStreaming(false)
        }
        // Free the resting engagement's slot when its pre-rendered cell
        // leaves WITHOUT settling — a text page scrolled in (pre-rendered
        // on visibility) then scrolled back out never activates, so the
        // `apply` resign leg never fires for it; without this the slot
        // stays stuck on an off-screen cell and the next text page can't
        // pre-render. Never tears down the SETTLED engaged page (it stays
        // put until a real page change).
        if let engagedID = commentsEngagedID, commentsEngagementIsResting,
           orderedIDs.indices.contains(indexPath.item),
           orderedIDs[indexPath.item] == engagedID,
           lifecycle.activeIndex != indexPath.item,
           // UIKit calls this when the cell leaves the MODEL's viewport, which
           // during a settle is a moment too early — see `isPostOnScreen`.
           !commentsCoordinator.isPostOnScreen(engagedID) {
            commentsCoordinator.finishCommentsDisengagement()
            // The slot is free at last — and the page that is now active may
            // have been showing a PREVIEW since it scrolled in, waiting for
            // exactly this. Promoting is a field assignment; without it the
            // preview would stay one for ever and its page would never own its
            // own pager lock.
            if let active = activePostID { commentsCoordinator.promoteRestingPreview(for: active) }
        }
    }

    // A full-cell tap toggles play/pause (handled by the cell's own gesture),
    // not navigation — so there is no `didSelectItemAt` routing. Comments open
    // via the toolbar's more menu; the identity pill opens the profile.

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        // A landing cover still waiting for the page's picture is an inert
        // still of the post that opened; the viewer is now moving the pages
        // under it, so it goes, and adopts nothing (`ZoomLandingLeftovers`).
        if scrollView === collectionView { ZoomLandingLeftovers.clear(over: view) }
        // The feed taken up again after a close: the next opening is the
        // post on show's own list (#1580). The viewer's drag, never a settle
        // — the close's own re-settle passes through other posts.
        if scrollView === collectionView, !viewModel.isInSideListSession { sideListSession.forgetResume() }
    }

    /// ⚠️ THE FLICK STOPS AT THE LAST PAGE THAT IS READY.
    ///
    /// The pager's own paging is what carries a media page, and it will happily
    /// land on a post whose interface has not been built — which is the black
    /// rectangle that fills itself in. Clamping the TARGET rather than the live
    /// offset keeps the drag itself free: the viewer can pull the next page
    /// into view and see the loader under it, and the release settles back.
    ///
    /// A page that is not ready reads as the end of the feed, because that is
    /// what it is for the moment: more is coming and it is not here yet.
    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        let page = scrollView.bounds.height
        guard page > 0 else { return }
        let ceiling = CGFloat(reachableCeiling()) * page
        if targetContentOffset.pointee.y > ceiling {
            targetContentOffset.pointee.y = ceiling
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // ⚠️ NO ACTIVATION HERE. Activating at the halfway mark was tried, to
        // start a video as soon as its page owned most of the screen, and it
        // moved the SCROLL: activation runs the settle's whole choreography —
        // which includes bringing the active page clear of the chrome — so the
        // feed jumped to the next page in the middle of the gesture. Reported
        // as worse than the delay it was meant to fix, and it was.
        //
        // Starting playback early has to be a playback-only path, not a second
        // caller of the seam that owns everything else — which is exactly what
        // `updateViewportPlayback` is: it moves the picture and touches
        // nothing else on the screen.
        // The items are being swapped under the post on show (#1580):
        // nothing reads the visible cells now — asking forces a layout of the
        // OLD items at the NEW offset, which takes the post's cell off screen
        // and recycles it, its player with it.
        guard !isReplacingItems else { return }
        updateViewportPlayback()
        pageLoaders.updatePagingFooter(for: scrollView)
        // The card's crop is in the pager's own space, which its scroll moves.
        if scrollView === collectionView {
            sideList?.pagerDidScroll()
            sideListSession.updateSideListRing(scrollView)
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        updateActiveItem()
        pageLoaders.updatePagingFooter(for: scrollView)
    }

    /// A programmatic animated scroll (the own-post reveal) ends here, never
    /// in the drag callbacks — without it the page it lands on is never
    /// settled.
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        updateActiveItem()
        pageLoaders.updatePagingFooter(for: scrollView)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            updateActiveItem()
        }
        pageLoaders.updatePagingFooter(for: scrollView)
    }
}

extension SnapFeedViewController: UICollectionViewDataSourcePrefetching {
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        warmPlanner.warmContent(at: indexPaths.map(\.item))
        warmPlanner.warmPlayers(at: indexPaths.map(\.item))
    }

}
