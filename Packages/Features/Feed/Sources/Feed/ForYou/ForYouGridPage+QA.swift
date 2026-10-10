#if DEBUG
import CoreModels
import CoreNavigation
import CoreStorage
import DesignSystem
import FeedInterface
import MediaCore
import MediaPlayback
import PostGrid
import UIKit

// MARK: - QA hooks
//
// The page's scripted drives, the `debug*` accessors that read nothing
// private beyond the members widened for them, the `-grid-playback-log`
// sampler and the arrival facts. The ranking, carousel, segment and
// visibility logs stay in `ForYouGridPage.swift`, with the accessors that
// read private layout or playback state: each reads state a file of its own
// could only reach by widening it. Stored DEBUG properties stay with the type.

// MARK: - Drives and accessors

extension ForYouGridPage {
    /// Pulls the page `distance` past its top and lets go, through the drag's
    /// own delegate callback — what a finger reaches. A scripted offset alone
    /// never ends a drag, so it never asks for a refresh.
    func debugReleasePull(by distance: CGFloat) {
        setVerticalOffset(-distance)
        scrollViewDidEndDragging(collectionView, willDecelerate: false)
        // And springs back, as a released page does.
        setVerticalOffset(0)
    }

    /// Whether the page still carries the stock control.
    var debugHasRefreshControl: Bool { collectionView.refreshControl != nil }

    /// Drives the page's real selection path, the one a finger reaches.
    ///
    /// `-foryou-open` used to call `openFeed` directly, which skipped
    /// `didSelectItemAt` entirely — so nothing scripted ever exercised what a
    /// tap actually does, and the scroll-into-view work went three rounds with
    /// no run able to reach it. Going through the delegate means a scripted
    /// open and a real one differ only in what produced the touch.
    func debugSelectItem(at index: Int) -> Bool {
        guard posts.indices.contains(index) else { return false }
        collectionView(collectionView, didSelectItemAt: indexPath(for: index))
        return true
    }

    /// Presses a row's comment count, the control a finger reaches — not the
    /// route behind it. Reports false when the row is not on screen or wears no
    /// chip, which is what separates "the shortcut is broken" from "there was
    /// nothing to press".
    func debugTapComments(at index: Int) -> Bool {
        guard posts.indices.contains(index),
              let row = collectionView.cellForItem(
                  at: indexPath(for: index)
              ) as? PostGridListRowCell
        else { return false }
        return row.debugTapCommentsChip()
    }

    /// `-foryou-scroll-demo`: scrolls the page the way a finger would, since
    /// the simulator injects no touches.
    ///
    /// Deliberately `setContentOffset(animated:)` rather than assigning the
    /// offset: an assignment jumps in one step and fires a single
    /// `scrollViewDidScroll`, which would exercise none of what autoplay does
    /// during a scroll. The animated form emits a callback per frame and ends
    /// with `scrollViewDidEndScrollingAnimation`, so the throttled reconcile,
    /// its velocity gate and the settle all run exactly as they do under a
    /// flick.
    func debugScroll(toY y: CGFloat) {
        collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: true)
    }

    var debugScrollableHeight: CGFloat {
        max(0, collectionView.contentSize.height - collectionView.bounds.height)
    }

    var debugViewportHeight: CGFloat { collectionView.bounds.height }

    /// The topmost realized item, and where its top edge is in `space` — what
    /// `-list-jump-trace` follows across a post's open and close.
    func debugFirstVisibleItem(in space: UICoordinateSpace) -> (id: String, minY: CGFloat)? {
        let top = collectionView.indexPathsForVisibleItems.min {
            ($0.section, $0.item) < ($1.section, $1.item)
        }
        guard let top, let cell = collectionView.cellForItem(at: top),
              posts.indices.contains(flatIndex(for: top)) else { return nil }
        return (posts[flatIndex(for: top)].id.rawValue, cell.convert(cell.bounds, to: space).minY)
    }

    /// `-foryou-expand <index>`: presses the row's "Show more". Returns false
    /// when the row is not realized or its caption fits, so a harness can tell
    /// "did not expand" from "had nothing to expand".
    @discardableResult
    func debugTapShowMore(atIndex index: Int) -> Bool {
        guard posts.indices.contains(index) else { return false }
        let path = indexPath(for: index)
        // Scroll ONLY if the row is not already realized. Scrolling anyway is
        // what the first version did, and it made the expansion impossible to
        // film: every frame of the capture was the list travelling, with the
        // growth buried inside it.
        if collectionView.cellForItem(at: path) == nil {
            collectionView.scrollToItem(at: path, at: .centeredVertically, animated: false)
            collectionView.layoutIfNeeded()
        }
        guard let row = collectionView.cellForItem(at: path) as? PostGridListRowCell
        else { return false }
        return row.debugTapShowMore()
    }

    /// Swipes a row's carousel to a page. Same realize-then-act shape as
    /// `debugTapShowMore(atIndex:)`, and false for a row with no collection.
    @discardableResult
    func debugScrollCarousel(atIndex index: Int, toPage page: Int) -> Bool {
        guard posts.indices.contains(index) else { return false }
        let path = indexPath(for: index)
        if collectionView.cellForItem(at: path) == nil {
            collectionView.scrollToItem(at: path, at: .centeredVertically, animated: false)
            collectionView.layoutIfNeeded()
        }
        guard let row = collectionView.cellForItem(at: path) as? PostGridListRowCell
        else { return false }
        return row.debugScrollCarousel(toPage: page)
    }
}

// MARK: - Playback diagnostics

extension ForYouGridPage {
    /// `-grid-playback-log`: report which ladder rung each playing tile settled
    /// on, once the streams have had time to choose one.
    func schedulePlaybackDiagnosticsIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("-grid-playback-log"),
              let playback, !hasScheduledDiagnostics
        else { return }
        hasScheduledDiagnostics = true
        // Sampled rather than taken once: a stream needs a few seconds to pick
        // a rung, and the first sample often lands before content has even
        // loaded. Three samples show the settle instead of guessing at it.
        for delay in [8.0, 16.0, 24.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                print("[grid-playback] --- t+\(Int(delay))s ---")
                self?.updateAutoplay()
                playback.logPlaybackDiagnostics()
            }
        }
    }
}

extension ForYouGridPage: ArrivalInvariantReportingView {
    /// ⚠️ A grid at rest has no playback handoff open. Every host begins one
    /// when it opens a post and must end it when the screen is back; Search
    /// began and never ended, which froze the tapped tile out of the grid's
    /// ranking for the rest of the session (hero audit 1.5). Stated here, once,
    /// every host of this page is checked.
    func arrivalFacts() -> [(name: String, holds: Bool)] {
        [("grid.handoffClosed", !(playback?.isHandoffOpen ?? false))]
    }
}
#endif
