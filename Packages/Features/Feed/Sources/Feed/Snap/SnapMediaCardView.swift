import DesignSystem
import MediaCore
import MediaPlayback
import UIKit

/// The post's media surface: an image view for photos and a
/// `VideoRenderView` for videos, hosted full-bleed as one standalone piece.
/// Playback is never re-hosted here — its clock and ownership are the
/// caller's, driven into `renderView`.
///
/// The surfaces are FULL-BLEED IN BOTH STATES, at identity, with square
/// corners. Engaging the comments layers a readability treatment and the
/// stream OVER this view; it does not move, scale, crop, round, or stop.
/// (A slight scale-down and a screen-concentric corner rounding rode the
/// engagement for a while, meant to read as the post stepping back. At a
/// 6pt pullback it read as a phantom layer sliding under the content
/// instead, so the engagement now touches this view's geometry not at all.)
///
/// (It used to dock into an 88pt tile — a uniform
/// transform plus an animated center-crop mask, plus its own glass card.
/// That machinery is gone with the tile, and so is the doctrine it forced:
/// while the engagement owned the media's transform, every path that reset
/// that transform had to branch on `isCommentsEngaged`, and the ones that
/// forgot produced a frozen full-bleed center crop that nothing could heal.
/// Identity throughout means there is no state to strand.)
///
/// The card owns the surfaces' MOTION (the Ken Burns drift); the cell
/// orchestrates WHEN — playback activation, the drift's active/engaged
/// gating — since those are lifecycle decisions the surface can't see.
/// Text-only posts leave both surfaces hidden.
final class SnapMediaCardView: UIView {
    /// The photo surface (also the Ken Burns drift target). Exposed so the
    /// cell can load an image into it; the card owns its transform.
    let imageView = UIImageView()
    /// The video playback surface — the caller drives its external
    /// `VideoPlaybackController` into this (playback ownership stays out
    /// of the card by construction).
    private(set) var renderView: VideoRenderView = {
        let view = VideoRenderView()
        #if DEBUG
        view.debugLabel = "feed"
        #endif
        return view
    }()

    init() {
        super.init(frame: .zero)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.pin(to: self)
        renderView.pin(to: self)
    }

    /// Re-installs the video surface after a hero flight borrowed it.
    ///
    /// Removing the view drops its pinning constraints with it, so the restore
    /// has to re-pin rather than just re-add. Ordering matters as much: it goes
    /// back above the photo surface, where it started.
    func restoreRenderView(_ view: VideoRenderView) {
        guard view.superview !== self else { return }
        // A LANDING hands over the other side's surface, not the one this card
        // started with — the view travels tile -> flight card -> page (and back
        // on a dismissal) so the layer is never re-created. Adopt it as this
        // card's own and drop the surface it replaces.
        if view !== renderView {
            renderView.detachForReplacement()
            renderView.removeFromSuperview()
            renderView = view
        }
        view.transform = .identity
        // Installed by FRAME, not by constraints, and that is the whole fix for
        // the landing flash. `pin(to:)` sets
        // `translatesAutoresizingMaskIntoConstraints = false`, which discards
        // the view's concrete frame until the next layout pass; the transient
        // bounds reset `AVPlayerLayer.isReadyForDisplay` to false for ~170ms,
        // measured, exactly on the completion frame. The takeoff path installs
        // by frame and never resets — this now matches it.
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        insertSubview(view, aboveSubview: imageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The card is HIT-TRANSPARENT except where its surfaces actually are.
    /// It hosts the surfaces full-bleed, so without this its own frame
    /// would eat every touch on the cell. Returning nil for a self-hit
    /// makes only the surfaces hittable. (Still load-bearing after the
    /// dock's removal, for a new reason: the card now sits BENEATH the
    /// engaged stream rather than above it, and a full-bleed view that
    /// answers every point would still claim the background taps the
    /// chrome's own canvas rule is there to release.)
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
        logMediaState("configure(kind: \(kind))")
    }

    func setImage(_ image: UIImage?) {
        imageView.image = image
        logMediaState(image == nil ? "setImage(nil)" : "setImage(image)")
    }

    func setPoster(_ image: UIImage?) {
        renderView.setPoster(image)
        logMediaState(image == nil ? "setPoster(nil)" : "setPoster(image)")
    }

    /// Traces every mutation of the media area under `-media-log`.
    ///
    /// A black media area is always some combination of: the image view empty
    /// or hidden, the render surface hidden, its poster cleared, its layer
    /// flushed. Reasoning about which from the code has now been wrong three
    /// times in a row on this issue, so this prints the whole state on every
    /// change and lets the sequence say what happened. The gap to look for is a
    /// long interval between a clearing call and the call that refills it.
    private func logMediaState(_ event: String) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-media-log") else { return }
        print(String(format: "[media] %.3f %-22@ image=%@ imageHidden=%@ | render %@",
                     CACurrentMediaTime(), event,
                     imageView.image == nil ? "nil" : "set",
                     imageView.isHidden ? "Y" : "N",
                     renderView.debugSurfaceState))
        #endif
    }
    /// Whether the photo surface has something on screen — the landing
    /// trace's readiness signal for an image page.
    var isImageReady: Bool { imageView.image != nil && !imageView.isHidden }

    // MARK: - No transform. Ever.
    //
    // THE MEDIA IS STATIC, at `.identity`, for the whole life of the cell.
    // A Ken Burns drift used to live here — an 8s linear zoom to 1.12× on
    // the photo, started on activation — and it was the last thing scaling
    // this surface. It came from Phase 1, as visible proof that the
    // activation seam fired at all, back when video could not yet play; the
    // player has made that point for a long time now.
    //
    // What it cost was the engagement's transition. The comments have to
    // read over a STILL background, so engaging had to stop the drift — a
    // snap back from wherever the zoom had reached — and disengaging
    // restarted it, which began an 8s zoom inside the transition's own
    // animation block. From the reader's side that is the media scaling as
    // the comments open and close: not a designed motion, a side effect of
    // one state having to undo another's transform.
    //
    // Nothing sets a transform on these surfaces now, so there is no state
    // to reset, nothing to gate on `isCommentsEngaged`, and no path that
    // can strand a scale. The two `.identity` assignments at build time are
    // the whole story.
}
