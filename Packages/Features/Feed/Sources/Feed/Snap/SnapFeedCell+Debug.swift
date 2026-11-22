import MediaCore
import MediaPlayback
import UIKit

// The page's DEBUG accessors, for the tests and the landing probes — out of
// `SnapFeedCell.swift` (#2521), whose members they read.
#if DEBUG
extension SnapFeedCell {
    /// The photograph the page is drawing, for a test.
    var debugShownPhoto: UIImage? { mediaCard.imageView.image }

    var debugShowsUnavailableBlock: Bool { unavailablePost.debugShowsUnavailableBlock }

    var debugChrome: SnapChromeView { chrome }
    /// The two stages' opacities, and whether they take touches (#1915).
    var debugStageAlphas: [CGFloat] { stages.map(\.alpha) }
    var debugStagesTakeTouches: Bool { stages.allSatisfy(\.isUserInteractionEnabled) }
    /// Whether anything is animating the grab's stages or its window (#2362).
    var debugGrabAnimates: Bool {
        stages.contains { $0.layer.animationKeys() != nil }
            || pageGrab.flightMask?.layer.animationKeys() != nil
    }
    var debugChromeInsets: UIEdgeInsets { frozenInsets }

    /// Whether the page is announcing a wait, asked of the media area rather
    /// than of any bookkeeping.
    var debugIsShowingMediaLoader: Bool { mediaCard.isShowingLoader }
    /// Whether the page shows its picture's failure mark (#1767).
    var debugShowsPictureFailure: Bool { mediaCard.debugShowsPictureFailure }
    /// Fails the page's photograph as the pipeline would.
    func debugFailPicture() { mediaCard.debugFailPicture() }

    /// The surface the page is CURRENTLY showing — which is not the one it was
    /// built with once a landing has handed one over. A spec that wants to
    /// prove the page's picture signal followed the surface has to be able to
    /// name both.
    var debugRenderView: VideoRenderView { mediaCard.renderView }

    /// WHERE the wait is drawn — the view itself, so a spec can prove it rides
    /// its own picture rather than the post.
    func debugLoaderView(onPage page: Int) -> UIView? {
        mediaCard.visibleLoader(onPage: page)
    }

    /// Runs the grace out now, so a spec does not have to sleep for it.
    func debugElapseMediaLoaderGrace() {
        mediaWait.debugElapseGrace()
    }

    /// The media area's full state for the landing trace.
    var debugMediaState: String {
        "kind=\(mediaKind) url=\(mediaURL == nil ? "nil" : "set") render[\(mediaCard.renderView.debugSurfaceState)]"
    }

    /// The page's playback surface, for a test that needs to ask the pool about
    /// it. Playback ownership is the pool's, so a test has to name the surface.
    var debugRenderSurface: VideoRenderView { mediaCard.renderView }

    /// Whether the page's playhead feed runs (#1532). Tests.
    var debugIsFeedingPlayhead: Bool { playback.isFeedingPlayhead }

    /// Whether the centred glyph is up — the page's own account of "the viewer
    /// stopped this", which is the half of the gesture a screenshot can see.
    var debugIsShowingPauseGlyph: Bool { mediaCard.showsPausedMark }

    /// Where a given page's stopped mark is drawn, in the CELL's coordinates —
    /// nil when that page wears none. The claim it exists to check is that the
    /// mark moved WITH the page rather than staying centred on the screen.
    /// (A single-attachment post has one picture, and answers for any page.)
    func debugPausedMarkFrame(onPage page: Int) -> CGRect? {
        mediaCard.visiblePausedMark(onPage: page).map { $0.convert($0.bounds, to: self) }
    }

    /// The clip's territory as a rectangle, so a spec can state its edges
    /// against the screen's thresholds rather than against numbers of its own.
    var debugPlaybackTapRegion: CGRect { mediaTaps.playbackTapRegion }

    /// Puts the watched surface on the page the card is showing — the piece of
    /// activation a spec needs without activation's asynchronous start (which
    /// a fixture cannot race without becoming time-dependent).
    func debugHostRenderViewOnCurrentPage() {
        mediaCard.hostRenderViewOnCurrentPage()
    }

    /// Asks for a page exactly as the strip's tap does, so a spec drives the
    /// cell's own answer to that request rather than a route nobody uses.
    func debugRequestMediaPage(_ page: Int) {
        chrome.mediaStrip.onMediaPageRequested?(page)
    }

    /// Every page instruction this cell has sent its card, in order — see the
    /// card's own note on why the decisions are what a spec can hold onto.
    var debugPageRequests: [(page: Int, animated: Bool)] { mediaCard.debugPageRequests }

    /// Forgets them, so a case can read one tap at a time.
    func debugClearPageRequests() { mediaCard.debugClearPageRequests() }

    /// Moves the collection to a page as a viewer's swipe would.
    ///
    /// The simulator injects no touches and a unit test has no gesture, so this
    /// is how the event this whole file turns on is reached. It goes through
    /// `setPage`, not around it — the page change must arrive by the same path
    /// a real swipe takes, or a test would be pinning a route nobody uses.
    func debugShowPage(_ index: Int) {
        mediaCard.setPage(index, animated: false)
    }

    /// The page this post's collection is actually showing, so a test can ask
    /// the CARD rather than trusting the instruction that was sent to it.
    var debugCurrentMediaPage: Int { mediaCard.currentPage }

    /// Which pages are holding a playback surface — the retention window's
    /// footprint, which is otherwise invisible from outside.
    var debugSurfacedPages: [Int] { mediaCard.surfacedPages }

    /// The surface a given page is holding, so a test can ask the POOL what is
    /// behind it rather than trusting the cell's own account.
    func debugSurface(forPage page: Int) -> VideoRenderView {
        mediaCard.surface(forPage: page)
    }
}
#endif
