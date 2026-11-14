import CoreModels
import CoreStorage
import DesignSystem
import EmoteKit
import MediaCore
import MediaPlayback
import UIKit
import VoiceKitUI

// Retained clips: the surfaces a row keeps, prewarms, adopts and donates
extension PostGridListRowCell {
    // MARK: - Retained clips



    /// The surface belonging to the page the viewer is actually looking at.
    ///
    /// ⚠️ ASKED OF THE CAROUSEL, NEVER REMEMBERED — and that is the whole of a
    /// reported defect.
    ///
    /// `loadedVideoRenderView` is re-pointed when someone asks the cell for a
    /// surface, which happens in the coordinator's START pass. Anything running
    /// BEFORE that — the pause pass, in particular — reads the page the viewer
    /// has just left. Pausing "everything except the watched one" then spared
    /// the clip being left and paused the one arriving, so a card's carousel
    /// ended up with two clips playing at once.
    ///
    /// A still page has no watched clip, which is the honest answer: nothing on
    /// it should be advancing.
    public var watchedClipSurface: VideoRenderView? {
        guard showsCarousel, let carousel else { return loadedVideoRenderView }
        return pageSurfaces[carousel.currentPage]
    }

    public var retainedPlaybackSurfaces: [VideoRenderView] {
        var surfaces = Array(pageSurfaces.values)
        if let loadedVideoRenderView,
           !surfaces.contains(where: { $0 === loadedVideoRenderView }) {
            surfaces.append(loadedVideoRenderView)
        }
        return surfaces
    }

    @discardableResult
    public func retainClips(budget: Int) -> [VideoRenderView] {
        clipBudget = budget
        guard showsCarousel, let carousel else { return [] }
        // One policy, in one place: the same window the post page uses. The
        // budget is the EXTRA allowance, so the watched clip is added back — a
        // row granted nothing still keeps the one it is playing.
        let keep = Set(CarouselRetentionWindow.pagesToRetain(
            videoPages: carousel.videoPageIndices,
            currentPage: carousel.currentPage,
            capacity: budget + 1
        ))
        var dropped: [VideoRenderView] = []
        for (page, view) in pageSurfaces where !keep.contains(page) {
            guard view !== loadedVideoRenderView else { continue }
            carousel.evictSurface(onPage: page)
            view.removeFromSuperview()
            pageSurfaces[page] = nil
            dropped.append(view)
        }
        // Re-hung every time, and idempotent: a page whose surface is still its
        // own but whose carousel was re-laid out has to be put back.
        for (page, view) in pageSurfaces {
            view.translatesAutoresizingMaskIntoConstraints = true
            carousel.host(view, onPage: page)
        }
        return dropped
    }

    /// The clips this row would like brought to their first frame, each with a
    /// surface ready to receive one.
    ///
    /// The surface carries THAT page's cover as its poster: hosted without one
    /// it is a black rectangle over the photograph until the stream fills,
    /// which is a worse fault than the delay the warming is there to remove.
    public func clipsToPrewarm() -> [(url: URL, surface: VideoRenderView)] {
        guard showsCarousel, clipBudget > 0, let carousel else { return [] }
        let pages = CarouselRetentionWindow.pagesToPrewarm(
            videoPages: carousel.videoPageIndices,
            currentPage: carousel.currentPage,
            budget: clipBudget
        )
        return pages.compactMap { page in
            guard let url = carousel.videoURL(onPage: page) else { return nil }
            let view: VideoRenderView
            if let existing = pageSurfaces[page] {
                view = existing
            } else {
                view = VideoRenderView()
                #if DEBUG
                view.debugLabel = "row-warm-p\(page)"
                #endif
                view.isUserInteractionEnabled = false
                pageSurfaces[page] = view
            }
            view.setPoster(carousel.cover(onPage: page))
            view.isHidden = false
            view.translatesAutoresizingMaskIntoConstraints = true
            carousel.host(view, onPage: page)
            return (url, view)
        }
    }

    /// Gives up every clip surface but the watched one — for reuse, and for the
    /// end of this row's playback.
    @discardableResult
    public func releaseRetainedClips() -> [VideoRenderView] {
        var dropped: [VideoRenderView] = []
        for (page, view) in pageSurfaces where view !== loadedVideoRenderView {
            carousel?.evictSurface(onPage: page)
            view.removeFromSuperview()
            pageSurfaces[page] = nil
            dropped.append(view)
        }
        return dropped
    }

    /// For a collection: only while the surface hangs in the page being looked
    /// at. A paused clip one page over is rendering, and is not what the viewer
    /// is looking at.
    public var isRenderingCurrentMedia: Bool {
        guard let view = loadedVideoRenderView else { return false }
        guard showsCarousel, let carousel else { return true }
        return carousel.hostsSurfaceOnCurrentPage(view)
    }

    /// Whether the surface could actually put pixels on screen: on the page
    /// being looked at, visible, and not sitting at zero alpha behind a flight.
    public var isSurfaceDrawable: Bool {
        guard let view = loadedVideoRenderView else { return false }
        return !view.isHidden && view.alpha > 0 && isRenderingCurrentMedia
    }

    /// ⚠️ The CONVERSE fault: a clip drawing on a page that has none.
    ///
    /// The audit's first invariant only asked whether a clip's page was showing
    /// its clip. It could not see the opposite — a surface hosted on a
    /// PHOTOGRAPH — and that is the shape the flight defect took: the card swapped
    /// to the video at the moment of the tap, on a page that carries no video at
    /// all. Both directions are the same requirement stated once: what is on a
    /// page is what that page is.
    /// The surface, for a host that needs to ask the pool about it.
    public var playbackSurface: VideoRenderView? { loadedVideoRenderView }

    public var drawsVideoOnAStillPage: Bool {
        guard let view = loadedVideoRenderView, !view.isHidden, view.alpha > 0,
              showsCarousel, let carousel
        else { return false }
        return carousel.currentPageVideoURL == nil
            && carousel.hostsSurfaceOnCurrentPage(view)
    }

    public func adoptVideoRenderView(_ view: VideoRenderView) {
        if let existing = loadedVideoRenderView, existing !== view {
            existing.detachForReplacement()
            existing.removeFromSuperview()
        }
        view.transform = .identity
        view.isHidden = false
        // ⚠️ THE ADOPTED VIEW IS THIS PAGE'S SURFACE FROM HERE ON.
        //
        // Without this the page map still names the surface the landing just
        // replaced, and the live one — the view actually carrying the adopted
        // player — is in no map at all. Nothing can pause what it cannot name,
        // so that player ran on for as long as the row lived: returning to its
        // page found playback seconds ahead of where it was left, and the
        // picture raced to reach it.
        //
        // Reported precisely: "in the post it pauses properly, in the card the
        // video catches up as if it had kept going". It had. The post's card
        // view took this same line when its own landing was fixed; the row
        // never got it, and that asymmetry is exactly what was observed.
        if showsCarousel, let carousel, carousel.currentPageVideoURL != nil {
            pageSurfaces[carousel.currentPage] = view
        }
        install(view)
        loadedVideoRenderView = view
    }

    public func donateVideoRenderView() -> VideoRenderView? {
        guard let view = loadedVideoRenderView else { return nil }
        loadedVideoRenderView = nil
        // Told, not inferred. Removing the view from its superview leaves a
        // carousel page still believing it holds one — its reference is weak
        // and the flight card retains the view — and a page that believes that
        // refuses to take it back.
        carousel?.evictHostedSurface()
        view.removeFromSuperview()
        return view
    }

    /// Reveals the surface once a player has been attached. The cover stays
    /// underneath as the poster, so the first frame replaces it rather than
    /// flashing black.
    public func beginVideoPreview() {
        let view = makeVideoRenderViewIfNeeded()
        // `renderedCover`, not `mediaView.image`: on a collection the box's own
        // image view is empty — the pages hold the pictures — so the poster
        // would have been nil and the surface would have shown black until the
        // first frame decoded.
        view.setPoster(renderedCover)
        view.revealOnFirstFrame()
    }

    /// Back to a still row. Faded rather than switched off, so a sweep that
    /// stops several rows at once does not snap their covers back in one frame.
    public func endVideoPreview() {
        loadedVideoRenderView?.hideCrossFading()
    }

    /// Puts a cover on immediately, without waiting for the async load already
    /// in flight — the same race the tile closes, for the same reason: the
    /// autoplay gate must not pass on a cover the row is not actually showing.
    public func applyCover(_ image: UIImage) {
        cover.apply(image)
    }

    /// The frame a return player was parked on (#895) REPLACES the thumbnail
    /// on a single-media row, as it does on a tile (#1069): a close whose
    /// player went lands on the picture the viewer left, not on an older
    /// one. A thumbnail still loading is dropped, or it would land over the
    /// frame. A collection keeps `applyCover`'s rule: its pages hold the
    /// pictures, and the box behind them has none to replace.
    public func showReturnStill(_ image: UIImage) {
        guard !showsCarousel else {
            applyCover(image)
            return
        }
        cover.showParked(image)
    }
}
