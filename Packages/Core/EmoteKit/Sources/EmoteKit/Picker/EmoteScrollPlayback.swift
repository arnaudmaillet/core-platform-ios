import UIKit

/// Plays a scroll view's emote tiles only while it moves under a finger —
/// one rule for the strip, the panel and the feed's shortcut rail, kept here
/// so they cannot drift.
///
/// ## The rule
///
/// At rest nothing moves: every tile shows a still frame — its poster frame
/// when it was dressed at rest (first appearance, a layout change, a jump
/// set in code). The displayed tiles play while the grid SCROLLS — from the
/// drag's start to the end of its glide — and a tile scrolled in meanwhile
/// plays from its first appearance. When the grid stops, each tile plays out
/// its current loop and rests on its poster frame (#559) — never posed
/// mid-gesture; a loop longer than `AnimatedIconView.maxFinishWait` holds
/// where it is instead. A scroll that starts again before then just carries
/// on. Leaving the window (`stop()`) is a hard stop: every tile holds at once. A still tile is a posed layer with no animation on
/// it, so a grid at rest costs the render server nothing
/// (`AnimatedIconView.pause` says why it is not a stopped layer clock).
///
/// ## Adopting it
///
/// The owner forwards its scroll view's drag and deceleration callbacks,
/// dresses each tile it brings on screen with `playing: isScrolling`, and
/// calls `stop()` when it leaves the window.
@MainActor
public final class EmoteScrollPlayback {
    private weak var scrollView: UIScrollView?
    /// The tiles on screen right now: the ones a start or a stop reaches.
    private let displayedTiles: @MainActor () -> [EmoteTileView]
    /// From a drag's start to the end of its glide.
    public private(set) var isScrolling = false
    /// While scrolling: ends it when a touch stopped the glide, which tells
    /// the delegate nothing.
    private var settleWatch: Task<Void, Never>?
    /// Whether the grid is still moving — what the settle watch asks before
    /// it ends a scroll. A seam: tests drive the delegate calls by hand, with
    /// no gesture behind them, and a watch ending their "scroll" mid-test made
    /// a frame they wait for impossible (#621).
    var gridIsMoving: @MainActor (UIScrollView) -> Bool = { grid in
        grid.isTracking || grid.isDragging || grid.isDecelerating
    }

    public init(scrollView: UIScrollView, displayedTiles: @escaping @MainActor () -> [EmoteTileView]) {
        self.scrollView = scrollView
        self.displayedTiles = displayedTiles
    }

    /// For a grid of `EmoteTileCell`s: its visible cells' tiles.
    convenience init(collectionView: UICollectionView) {
        self.init(scrollView: collectionView) { [weak collectionView] in
            (collectionView?.visibleCells ?? []).compactMap { ($0 as? EmoteTileCell)?.tile }
        }
    }

    public func willBeginDragging() {
        setScrolling(true)
    }

    public func didEndDragging(willDecelerate decelerate: Bool) {
        if !decelerate { setScrolling(false, finishingLoops: true) }
    }

    /// The glide ended, or a scroll animation set in code did.
    public func didEndScrolling() {
        setScrolling(false, finishingLoops: true)
    }

    /// A hard stop (leaving the window, new emotes): every tile holds where
    /// it is, now.
    public func stop() {
        setScrolling(false, finishingLoops: false)
    }

    /// Plays or stills every displayed tile. A scroll that ENDS lets each
    /// emote finish its loop and rest on its poster frame (#559).
    private func setScrolling(_ scrolling: Bool, finishingLoops: Bool = false) {
        guard scrolling != isScrolling else { return }
        isScrolling = scrolling
        for tile in displayedTiles() {
            tile.setPlaying(scrolling, finishingLoop: finishingLoops)
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
                guard let grid = self.scrollView else {
                    self.setScrolling(false)
                    return
                }
                if !self.gridIsMoving(grid) {
                    self.setScrolling(false, finishingLoops: true)
                }
            }
        }
    }
}
