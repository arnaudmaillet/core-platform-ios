import CoreModels
import CoreStorage
import DesignSystem
import EmoteKit
import MediaCore
import MediaPlayback
import UIKit
import VoiceKitUI

// The autoplay surface: the video render view a row hosts
extension PostGridListRowCell {
    // MARK: - Autoplay surface

    /// The surface an autoplaying row renders into, built on first use so a
    /// timeline of stills never allocates a player layer it will not use.
    ///
    /// Placed INSIDE the preview box, unlike the tile's, which fills the whole
    /// cell. That is the row's shape talking: the media is one part of a card,
    /// so the video has to be clipped to the part — and putting it in the box
    /// also means it inherits the box's rounding and, for free, the alpha that
    /// `setHeroMediaConcealed` applies while a twin is in the air. A sibling
    /// surface would have needed concealing separately, and would have been
    /// the thing left visible over a flight.
    ///
    /// ⚠️ For a collection it answers PER PAGE, once a budget has bought the row
    /// a second surface. Until then `pageSurfaces` holds at most the watched
    /// page and this behaves exactly as the single-surface version every
    /// existing caller was written against.
    public func makeVideoRenderViewIfNeeded() -> VideoRenderView {
        // ⚠️ GATED ON A GRANTED BUDGET, and this is not an optimisation.
        //
        // Minting per page regardless meant a row with no allowance still ended
        // up holding two surfaces — and the coordinator reads exactly that
        // ("more than one surface") to decide it may release a loan instead of
        // stopping it. So a row nobody had given anything to would leave the
        // previous clip's player bound, untracked and unreclaimable. With the
        // gate, a budget of zero is the old single-surface behaviour, exactly.
        if showsCarousel, clipBudget > 0, let carousel, carousel.currentPageVideoURL != nil {
            let page = carousel.currentPage
            if let existing = pageSurfaces[page] {
                loadedVideoRenderView = existing
                install(existing)
                return existing
            }
            // The row's first surface belongs to the first clip page that asks
            // for one: minting a second here would leave the original hanging
            // with a live player and no page to draw it on.
            if let inherited = loadedVideoRenderView,
               !pageSurfaces.values.contains(where: { $0 === inherited }) {
                pageSurfaces[page] = inherited
                install(inherited)
                return inherited
            }
            let view = VideoRenderView()
            #if DEBUG
            view.debugLabel = "row-p\(page)"
            #endif
            view.isHidden = true
            view.isUserInteractionEnabled = false
            pageSurfaces[page] = view
            loadedVideoRenderView = view
            install(view)
            return view
        }
        if let loadedVideoRenderView {
            // ⚠️ RE-INSTALLED, not just returned.
            //
            // On a collection the surface is evicted from its page on every
            // page change — it has to be, or a clip keeps drawing on the page
            // the viewer scrolled away from, which is still on screen peeking.
            // Returning the view without putting it back somewhere meant the
            // SECOND visit to a clip played into a view with no superview: the
            // coordinator reported a clean start, the pool decoded, and the
            // card showed a still. Autoplay worked exactly once per row.
            //
            // `install` no-ops when the surface is already where it belongs, so
            // the single-attachment path is untouched — re-pinning it would
            // reset `isReadyForDisplay` for ~170ms on every reconcile.
            install(loadedVideoRenderView)
            return loadedVideoRenderView
        }
        let view = VideoRenderView()
        #if DEBUG
        view.debugLabel = "row"
        #endif
        view.isHidden = true
        view.isUserInteractionEnabled = false
        install(view)
        loadedVideoRenderView = view
        return view
    }

    /// Puts the playback surface where the media the viewer is looking at
    /// actually is: pinned to the preview box for a single attachment, and
    /// re-parented onto the current PAGE for a collection.
    ///
    /// ⚠️ The two use different layout systems on purpose, and that is why this
    /// exists rather than a branch at each call site. The box is laid out by
    /// constraints; the carousel places its pages by FRAME on every width
    /// change, and a surface pinned by constraints inside one of them would
    /// fight the page it is sitting in. `removeFromSuperview` first, because
    /// that is what drops the constraints the previous home left on it.
    func install(_ view: VideoRenderView) {
        if showsCarousel, let carousel {
            // ⚠️ ONLY onto a page that carries a clip.
            //
            // This hosted on whatever page was current, which is fine while the
            // viewer is looking at the video and catastrophic one page over: any
            // caller asking for the surface — and the flight staging is one —
            // moved it onto the PHOTOGRAPH being read and drew the clip over it.
            // On screen the card swapped to the video at the instant of the tap,
            // and the flight then carried what it found.
            //
            // A still page is left alone. The surface stays where it belongs,
            // paused, and comes back when the viewer does.
            guard carousel.currentPageVideoURL != nil else { return }
            guard !carousel.hostsSurfaceOnCurrentPage(view) else { return }
            view.removeFromSuperview()
            view.translatesAutoresizingMaskIntoConstraints = true
            carousel.host(view)
            return
        }
        guard view.superview !== mediaView else { return }
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.pin(to: mediaView)
        // ⚠️ BEHIND EVERY OTHER SUBVIEW OF THE PREVIEW, and it takes a second
        // line to say so because `pin(to:)` begins with `addSubview` — which
        // puts the view at the FRONT. The preview's own subviews are its
        // furniture (the counters, the date, the page indicator), so a surface
        // left where it lands covers all of it: measured as "the counters and
        // the date disappear on single-video cards".
        //
        // The clip is CONTENT and the furniture is chrome, so the order is not
        // a detail of this one call — it is the same rule the cover obeys,
        // stated where the only view that can break it is inserted.
        mediaView.sendSubviewToBack(view)
    }
}
