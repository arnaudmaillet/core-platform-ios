import DesignSystem
import MediaCore
import MediaPlayback
import UIKit

/// The media component of the engaged card: the video/photo render
/// surfaces, their center-crop masking, and the top-left docking transform
/// — encapsulated as one standalone piece. It hosts BOTH surfaces (an
/// image view for photos, a `VideoRenderView` for videos) full-bleed, and
/// docks them into the card's square slot by a uniform transform + animated
/// crop mask, so the SAME live surface that fills the page shrinks into the
/// tile without a second render pass (playback is never re-hosted — its
/// clock and ownership are the caller's, driven into `renderView`).
///
/// The card owns the surfaces' GEOMETRY and MOTION (dock, undock, the
/// Ken Burns drift, the swipe nudge); the cell orchestrates WHEN — playback
/// activation, the drift's active/engaged gating — since those are
/// lifecycle decisions the surface can't see. Text-only posts omit this
/// component from the hierarchy entirely.
final class SnapMediaCardView: UIView {
    /// The photo surface (also the Ken Burns drift target). Exposed so the
    /// cell can load an image into it; the card owns its transform.
    let imageView = UIImageView()
    /// The video playback surface — the caller drives its external
    /// `VideoPlaybackController` into this (playback ownership stays out
    /// of the card by construction).
    let renderView = VideoRenderView()

    /// One center-crop mask per surface (a view masks only one other view);
    /// attached lazily on the first dock, animated full-bounds ↔ centered
    /// square, and dropped when the region is reclaimed.
    private let imageCropMask = UIView()
    private let videoCropMask = UIView()
    private var surfaces: [(view: UIView, mask: UIView)] {
        [(imageView, imageCropMask), (renderView, videoCropMask)]
    }
    /// This component's OWN floating glass card, drawn behind the docked
    /// tile at the media card frame — so the media renders as a distinct
    /// glass surface, independent of the info card beside it. Hidden while
    /// the media is full-bleed (default feed); shown while docked.
    private let glass = SnapGlassCardView()

    init() {
        super.init(frame: .zero)
        // The glass sits BEHIND the surfaces (a fixed-frame subview, not
        // full-bleed): the docked tile floats over its own glass card.
        glass.isHidden = true
        addSubview(glass)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.pin(to: self)
        renderView.pin(to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The card is HIT-TRANSPARENT except where its surfaces actually are.
    /// It hosts the surfaces full-bleed, so without this its own frame
    /// would eat every touch on the cell once the card is z-lifted over
    /// the comments stream during engagement. Returning nil for a self-hit
    /// makes only the surfaces hittable — in their TRANSFORMED regions, so
    /// a docked video tile still hit-tests exactly as the loose surface
    /// did (the cell's clip then trims its phantom band to the slot).
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    // MARK: - Content

    /// Selects the surface for the post's kind and clears any prior frame.
    func configure(kind: MediaKind) {
        imageView.isHidden = kind != .image
        renderView.isHidden = kind != .video
        imageView.image = nil
        imageView.transform = .identity
        renderView.setPoster(nil)
    }

    func setImage(_ image: UIImage?) { imageView.image = image }
    func setPoster(_ image: UIImage?) { renderView.setPoster(image) }
    /// Whether the drift has content to animate (a loaded, visible photo).
    var isImageReady: Bool { imageView.image != nil && !imageView.isHidden }
    /// Hit-test identity: whether a hit view is one of the card's surfaces.
    func containsSurface(_ view: UIView?) -> Bool {
        view === imageView || view === renderView
    }

    // MARK: - Docking

    /// Docks both surfaces into `slot` (a square in `bounds` coordinates):
    /// a uniform transform shrinks the full-bleed surface onto the tile
    /// while the mask re-CROPS it to a square (never squashes). Call inside
    /// the engagement's animation block — every mutation here is animatable.
    func dock(slot: CGRect, in bounds: CGRect) {
        let transform = SnapCommentsLayout.mediaTransform(bounds: bounds, slot: slot)
        let crop = SnapCommentsLayout.mediaCropFrame(in: bounds)
        let scale = dockScale(slot: slot, in: bounds)
        for (view, mask) in surfaces {
            if view.mask == nil {
                // Attach at full bounds (invisible crop) outside animation,
                // so only the frame close animates inside the spring.
                UIView.performWithoutAnimation {
                    mask.backgroundColor = .black
                    mask.frame = bounds
                    mask.layer.cornerCurve = .continuous
                    view.mask = mask
                }
            }
            // The radius lives on the mask (it owns the visible shape),
            // compensated for the scale it will be drawn under.
            mask.layer.cornerRadius = SnapCommentsLayout.mediaCornerRadius / scale
            mask.frame = crop
            view.transform = transform
        }
    }

    /// Reverses the dock — surfaces expand back to full-bleed, the crop
    /// reopens. The masks stay attached (visually inert at full bounds)
    /// until `clearMasks`. Call inside the disengagement's animation block.
    func undock(in bounds: CGRect) {
        for (view, mask) in surfaces {
            view.transform = .identity
            if view.mask != nil {
                mask.frame = bounds
                mask.layer.cornerRadius = 0
            }
        }
    }

    /// Re-asserts the docked geometry synchronously (no animation) — the
    /// belt for an outbound push that disturbed the tile while the feed was
    /// covered. Idempotent on an already-docked surface.
    func reassertDock(slot: CGRect, in bounds: CGRect) {
        let transform = SnapCommentsLayout.mediaTransform(bounds: bounds, slot: slot)
        let crop = SnapCommentsLayout.mediaCropFrame(in: bounds)
        let scale = dockScale(slot: slot, in: bounds)
        UIView.performWithoutAnimation {
            for (view, mask) in surfaces {
                view.transform = transform
                if view.mask != nil {
                    mask.frame = crop
                    mask.layer.cornerRadius = SnapCommentsLayout.mediaCornerRadius / scale
                }
            }
        }
    }

    /// The docked tile riding the finger: the swipe nudge composes ON TOP
    /// of the dock transform (the engagement owns the base dock).
    func applyDockNudge(dock: CGAffineTransform, nudge: CGAffineTransform) {
        let composed = dock.concatenating(nudge)
        for (view, _) in surfaces { view.transform = composed }
    }

    /// Settles the tile back onto the resting dock (release/cancel).
    func settleDock(to dock: CGAffineTransform) {
        for (view, _) in surfaces { view.transform = dock }
    }

    /// Drops the masks once the region is reclaimed — a full-bounds mask is
    /// visually inert but not free.
    func clearMasks() {
        imageView.mask = nil
        renderView.mask = nil
    }

    // MARK: - Glass card

    /// Shows this component's own glass card at `cardFrame` (the media card
    /// rect) — the docked tile floats over it. Call inside the engagement's
    /// animation block; the effect materializes window-guarded.
    func showGlass(at cardFrame: CGRect) {
        glass.isHidden = false
        glass.frame = cardFrame
        glass.setGlassActive(true)
    }

    /// Hides the glass on disengage (the media expands back to full-bleed).
    func hideGlass() {
        glass.setGlassActive(false)
        glass.isHidden = true
    }

    /// Nudges the glass with the swipe (the tile rides it as one body).
    func setGlassNudge(_ nudge: CGAffineTransform) {
        glass.transform = nudge
    }

    // MARK: - Ken Burns drift

    /// Starts the slow zoom on the photo surface. The caller gates WHEN
    /// (active and not engaged); the card owns the animation.
    func startDrift() {
        guard isImageReady else { return }
        imageView.layer.removeAllAnimations()
        UIView.animate(withDuration: 8, delay: 0, options: [.curveLinear, .allowUserInteraction]) {
            self.imageView.transform = CGAffineTransform(scaleX: 1.12, y: 1.12)
        }
    }

    /// Stops the drift and settles the photo onto a caller-computed resting
    /// transform (identity at rest, the dock while engaged — a blind
    /// identity here once stranded the docked tile as a full-bleed crop).
    func stopDrift(restingTransform: CGAffineTransform) {
        imageView.layer.removeAllAnimations()
        UIView.performWithoutAnimation { self.imageView.transform = restingTransform }
    }

    private func dockScale(slot: CGRect, in bounds: CGRect) -> CGFloat {
        slot.width / max(min(bounds.width, bounds.height), 1)
    }
}
