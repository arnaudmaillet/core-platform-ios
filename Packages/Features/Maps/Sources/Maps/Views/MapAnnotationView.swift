import CoreModels
import MapKit
import MediaCore
import MediaPlayback
import UIKit

/// A custom pin: the post's `thumbnail_url` rendered as a small rounded square
/// on the map surface (UX req #1), its exact center anchored on the coordinate.
/// A text-only post has no cover, so its marker wears `PinCardView`'s symbol
/// face instead: a smaller 44pt CIRCLE, sized and shaped by the face itself
/// (`applyFace`), so text posts read as lighter punctuation between the
/// photographs rather than as equal-weight squares.
/// The face itself is a `PinCardView` — the same component the hero transition
/// flies — so the pin and the flight card are twins by construction.
/// A play badge overlays video pins — dormant today because the Radar path
/// carries no media kind yet (see `GeoDiscoveryRepository`), and it lights up
/// automatically once field 5 lands.
final class MapAnnotationView: MKAnnotationView, MapVideoHost {
    static let reuseIdentifier = "MapAnnotationView"

    /// The LARGEST a marker gets — a media pin's square. Text markers are
    /// smaller (`PinCardView.Face.text.side`), so this stays the right number
    /// for anything sizing a worst case: the cluster grid's collision cell and
    /// the overlap guarantee both depend on it bounding every marker.
    static let side: CGFloat = PinCardView.Face.media.side

    /// The pin's face; also the exact blueprint of the flying card.
    let card = PinCardView(frame: CGRect(x: 0, y: 0, width: side, height: side))
    private let playBadge = UIImageView()
    private var imageTask: Task<Void, Never>?
    /// Separate from `imageTask`: a media pin loads its COVER and its PREVIEW,
    /// and one task handle for two loads cancels whichever started first.
    private var previewTask: Task<Void, Never>?
    /// Guards against a slow image load landing on a recycled view.
    private var representedID: PostID?

    /// Set by the view controller so the view can fetch its own thumbnail.
    var imagePipeline: ImagePipeline?

    /// Live-preview surface, overlaid on the thumbnail and shown only while this
    /// pin is one of the ≤3 the `MapVideoPlaybackCoordinator` has chosen to play.
    var videoRenderView: VideoRenderView { card.videoRenderView }

    /// The loaded cover image, handed to the hero transition to fly.
    var heroImage: UIImage? { card.imageView.image }

    /// Invoked when MapKit recycles this view, so the coordinator can return any
    /// player bound to it to the pool before it's reused for another pin.
    var onReuse: (() -> Void)?

    /// Fired the instant the pin is tapped — see `installInstantTap`.
    var onSelect: (() -> Void)?

    /// Reveals the live-preview surface over the thumbnail (playback is attached
    /// by the coordinator via `videoRenderView`). Seeds the render view's poster
    /// with the already-loaded thumbnail so the pin shows the still image — not a
    /// black frame — until the clip's first frame is ready.
    func beginVideoPreview() {
        card.videoRenderView.setPoster(card.imageView.image)
        card.videoRenderView.isHidden = false
    }

    /// Hides the preview and clears it back to the still thumbnail.
    func endVideoPreview() {
        card.videoRenderView.isHidden = true
        card.videoRenderView.setPoster(nil)
    }

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        // No `clusteringIdentifier`: `MapClusterEngine` computes the grouping,
        // so MapKit must not run its own clustering pass over these markers.
        // A plain square whose center sits exactly on the coordinate (no tail):
        // `centerOffset` stays zero so the marker doesn't drift on pan/zoom.
        frame = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
        centerOffset = .zero
        backgroundColor = .clear
        buildLayout()
        installInstantTap(target: self, action: #selector(handleTap))
    }

    @objc private func handleTap() { onSelect?() }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildLayout() {
        addSubview(card)

        // A soft drop shadow lifts the pin off the map tiles (the card clips,
        // so the shadow must live on this outer, non-clipping layer).
        PinCardView.applyPinShadow(to: layer)

        playBadge.image = UIImage(systemName: "play.circle.fill")?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 18, weight: .bold))
        playBadge.tintColor = .white
        playBadge.layer.shadowColor = UIColor.black.cgColor
        playBadge.layer.shadowOpacity = 0.5
        playBadge.layer.shadowRadius = 2
        playBadge.layer.shadowOffset = .zero
        playBadge.isHidden = true
        addSubview(playBadge)
        applyFace(.media)
    }

    /// Wears `face`: its shape AND its size. A text marker is a smaller circle,
    /// so the annotation view itself resizes — `bounds`, not `frame`, because
    /// MapKit owns the center (it re-anchors the view on the coordinate every
    /// layout pass, and `centerOffset` stays zero so the marker never drifts).
    ///
    /// Not animated: sizing happens on configure, which for a given marker
    /// runs once per post — the arrival is choreographed by
    /// `MapAnnotationPopChoreographer` on top of whatever size this settles.
    private func applyFace(_ face: PinCardView.Face) {
        let side = face.side
        if bounds.width != side {
            bounds = CGRect(x: 0, y: 0, width: side, height: side)
        }
        card.frame = bounds
        card.setFace(face)
        // ⚠️ RE-APPLIED per face, not set once at init: these views are
        // recycled across faces, so a card that last wore an icon (no shadow)
        // would hand that setting to the photograph that dequeues it next.
        PinCardView.applyPinShadow(to: layer, face: face)
        // The badge hangs off the card's own trailing-bottom corner, so it
        // tracks whichever size the face just chose.
        playBadge.frame = CGRect(x: side - 22, y: side - 22, width: 20, height: 20)
    }

    /// Renders the pin's thumbnail and (dormant) video badge — or, for a
    /// text-only post, the symbol face instead of a cover.
    func configure(
        with pin: MapPin, imagePipeline: ImagePipeline,
        iconCatalog: AnimatedIconCatalog? = nil, previewCatalog: AnimatedIconCatalog? = nil
    ) {
        self.imagePipeline = imagePipeline
        // Idempotent: a reconcile re-configures every surviving marker, so a
        // marker already showing this post must be left exactly as it is —
        // blanking and re-fetching an unchanged thumbnail is what flashes it.
        guard representedID != pin.postID else { return }
        representedID = pin.postID
        playBadge.isHidden = pin.kind != .video
        // Set on every configure, not only for text: this view is recycled, so
        // a media pin dequeuing a view that last wore the text face has to take
        // it off again — and get its square back.
        applyFace(PinCardView.Face.of(pin))

        imageTask?.cancel()
        card.imageView.image = nil
        // ⚠️ CLEARED ON EVERY CONFIGURE, like the cover above it: this view is
        // recycled, and a text marker dequeuing a view that last wore somebody
        // else's face would show that face until its own arrived.
        card.setTextAvatar(nil)
        card.setIcon(nil)
        card.setPreviewSheet(nil)

        // A media pin may carry a baked preview of its own footage. It sits OVER
        // the cover rather than replacing it: the cover is what shows while the
        // sheet loads, and what remains under Reduce Motion.
        if pin.hasPreviewSheet, let previewCatalog, let sheetID = pin.previewSheetID {
            let phase = pin.iconPhase
            if let art = previewCatalog.cached(sheetID) {
                card.setPreviewSheet((art, phase))
            } else {
                let id = pin.postID
                previewTask = Task { [weak self] in
                    guard let art = try? await previewCatalog.art(for: sheetID) else { return }
                    guard let self, self.representedID == id else { return }
                    self.card.setPreviewSheet((art, phase))
                }
            }
        }

        // An icon outranks the author's face: it is what the author CHOSE to
        // say about this post, where the avatar is only who they are.
        //
        // ⚠️ The synchronous peek first. An `await` here is a stall under the
        // finger during a pan, and it is also what would make the hero flight's
        // frame zero miss — the flying card is built from what the marker is
        // wearing at staging time, so an icon still in flight is an icon the
        // transition cannot copy.
        if pin.hasAnimatedIcon, let iconCatalog, let iconID = pin.animatedIconID {
            let phase = pin.iconPhase
            if let art = iconCatalog.cached(iconID) {
                card.setIcon((art, phase))
                return
            }
            let id = pin.postID
            imageTask = Task { [weak self] in
                guard let art = try? await iconCatalog.art(for: iconID) else { return }
                guard let self, self.representedID == id else { return }
                self.card.setIcon((art, phase))
            }
            return
        }

        // A text pin has no cover to fetch — it wears its AUTHOR instead, when
        // the pin knows one. Nil is the ordinary answer in production until
        // `RadarPin` carries an author (`dev/issues/BACKEND_MAP_PIN_AUTHOR.md`),
        // and the glyph is what the face shows without it.
        if pin.isText, let avatar = pin.authorAvatarURL {
            let id = pin.postID
            imageTask = Task { [weak self] in
                guard let image = try? await imagePipeline.image(for: avatar) else { return }
                guard let self, self.representedID == id else { return }
                self.card.setTextAvatar(image)
            }
            return
        }
        guard !pin.isText, let url = pin.thumbnailURL else { return }
        let id = pin.postID
        imageTask = Task { [weak self] in
            guard let image = try? await imagePipeline.image(for: url) else { return }
            guard let self, self.representedID == id else { return }
            self.card.imageView.image = image
            // If a live preview started before the thumbnail finished loading,
            // give it a poster now so the pin shows the still until the first
            // video frame — instead of a black square.
            if !self.card.videoRenderView.isHidden {
                self.card.videoRenderView.setPoster(image)
            }
        }
    }

    #if DEBUG
    /// Whether this marker is currently wearing baked artwork.
    var wearsAnimatedIcon: Bool { card.wornIcon != nil }

    /// The live-preview surface, for the debug readout.
    var videoSurface: VideoRenderView { card.videoRenderView }
    var isPlayingPreviewSheet: Bool { card.isPlayingPreviewSheet }

    /// A fingerprint of what the RENDER SERVER is presenting for this icon.
    ///
    /// Read from `presentation()`, never the model layer: the model keeps its
    /// resting value for the whole animation, so probing it would report a
    /// frozen icon as a running one.
    var presentedIconTick: Double? { card.presentedIconTick }
    var presentedPreviewTick: Double? { card.presentedPreviewTick }
    #endif

    /// Re-installs this marker's icon playback under the current motion policy.
    ///
    /// Unconditional: the policy can move in either direction, and a guard that
    /// checks "is it already animating" only ever handles one of them.
    func redressIcon() {
        card.reinstallIconPlayback()
        card.reinstallPreviewPlayback()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        // Pop state is per-APPEARANCE, not per-view: a marker retired mid-fade
        // goes back to the pool at alpha 0 and half scale, and the next pin to
        // dequeue it would be invisible until something happened to animate it
        // again. `MapAnnotationPopChoreographer` re-poses every view it pops
        // in, but a view can also be dequeued for a pin that never pops.
        alpha = 1
        transform = .identity
        onSelect = nil
        onReuse?()
        onReuse = nil
        endVideoPreview()
        imageTask?.cancel()
        imageTask = nil
        previewTask?.cancel()
        previewTask = nil
        representedID = nil
        card.setPreviewSheet(nil)
        card.imageView.image = nil
        // Cleared HERE as well as on configure. An animating icon left under a
        // photograph is worse than a stale avatar: it moves.
        card.setIcon(nil)
        card.setTextAvatar(nil)
        applyFace(.media)
        playBadge.isHidden = true
    }
}
