import UIKit

/// Plays a grid of emote tiles only while it moves under a finger — the
/// strip's and the panel's one rule, kept here so the two cannot drift.
///
/// ## The rule
///
/// At rest nothing moves: every tile shows a still frame — its poster frame
/// when it was dressed at rest (first appearance, a layout change, a jump
/// set in code). The displayed tiles play while the grid SCROLLS — from the
/// drag's start to the end of its glide — and a tile scrolled in meanwhile
/// plays from its first appearance. When the grid stops, each tile stops on
/// the frame it is on (no jump back to the poster, no flash); the next scroll
/// plays on from there. A still tile is a posed layer with no animation on
/// it, so a grid at rest costs the render server nothing
/// (`AnimatedIconView.pause` says why it is not a stopped layer clock).
///
/// ## Adopting it
///
/// The owner forwards its scroll view's drag and deceleration callbacks,
/// configures each dequeued tile with `playing: isScrolling`, and calls
/// `stop()` when it leaves the window.
@MainActor
final class EmoteScrollPlayback {
    private weak var collectionView: UICollectionView?
    /// From a drag's start to the end of its glide.
    private(set) var isScrolling = false
    /// While scrolling: ends it when a touch stopped the glide, which tells
    /// the delegate nothing.
    private var settleWatch: Task<Void, Never>?

    init(collectionView: UICollectionView) {
        self.collectionView = collectionView
    }

    func willBeginDragging() {
        setScrolling(true)
    }

    func didEndDragging(willDecelerate decelerate: Bool) {
        if !decelerate { setScrolling(false) }
    }

    /// The glide ended, or a scroll animation set in code did.
    func didEndScrolling() {
        setScrolling(false)
    }

    func stop() {
        setScrolling(false)
    }

    /// Plays or stills every displayed tile.
    private func setScrolling(_ scrolling: Bool) {
        guard scrolling != isScrolling else { return }
        isScrolling = scrolling
        for case let cell as EmoteTileCell in collectionView?.visibleCells ?? [] {
            cell.tile.setPlaying(scrolling)
        }
        settleWatch?.cancel()
        settleWatch = nil
        guard scrolling else { return }
        // ⚠️ A touch that stops a glide ends it without a delegate call:
        // neither `scrollViewDidEndDecelerating` nor a drag's end arrives.
        // A 4 Hz look for as long as the grid is scrolling catches it.
        settleWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self else { return }
                guard let grid = self.collectionView else {
                    self.setScrolling(false)
                    return
                }
                if !grid.isTracking, !grid.isDragging, !grid.isDecelerating {
                    self.setScrolling(false)
                }
            }
        }
    }
}
