import CoreModels
import MapKit
import MediaCore
import MediaPlayback
import UIKit

/// A custom pin: the post's `thumbnail_url` rendered as a small rounded square
/// on the map surface (UX req #1), its exact center anchored on the coordinate.
/// The face itself is a `PinCardView` — the same component the hero transition
/// flies — so the pin and the flight card are twins by construction.
/// A play badge overlays video pins — dormant today because the Radar path
/// carries no media kind yet (see `GeoDiscoveryRepository`), and it lights up
/// automatically once field 5 lands.
final class MapAnnotationView: MKAnnotationView {
    static let reuseIdentifier = "MapAnnotationView"

    static let side: CGFloat = 56

    /// The pin's face; also the exact blueprint of the flying card.
    private let card = PinCardView(frame: CGRect(x: 0, y: 0, width: side, height: side))
    private let playBadge = UIImageView()
    private var imageTask: Task<Void, Never>?
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
        clusteringIdentifier = MapAnnotation.clusteringIdentifier
        // A plain square whose center sits exactly on the coordinate (no tail):
        // `centerOffset` stays zero so the marker doesn't drift on pan/zoom.
        frame = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
        centerOffset = .zero
        backgroundColor = .clear
        buildLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// MapKit's designated "about to be shown" hook — including after reuse. We
    /// re-assert `clusteringIdentifier` here every time because a view dequeued
    /// out of a cluster comes back with its identifier consumed; during rapid
    /// zoom that silently disables clustering and dumps every pin on screen.
    /// Setting it deterministically on each display keeps clustering resilient.
    override func prepareForDisplay() {
        super.prepareForDisplay()
        clusteringIdentifier = MapAnnotation.clusteringIdentifier
    }

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
        playBadge.frame = CGRect(x: Self.side - 22, y: Self.side - 22, width: 20, height: 20)
        playBadge.isHidden = true
        addSubview(playBadge)
    }

    /// Renders the pin's thumbnail and (dormant) video badge.
    func configure(with pin: MapPin, imagePipeline: ImagePipeline) {
        self.imagePipeline = imagePipeline
        representedID = pin.postID
        playBadge.isHidden = pin.mediaKind != .video

        imageTask?.cancel()
        card.imageView.image = nil
        guard let url = pin.thumbnailURL else { return }
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

    override func prepareForReuse() {
        super.prepareForReuse()
        // Pop state is per-APPEARANCE, not per-view: a marker retired mid-fade
        // goes back to the pool at alpha 0 and half scale, and the next pin to
        // dequeue it would be invisible until something happened to animate it
        // again. `MapAnnotationPopChoreographer` re-poses every view it pops
        // in, but a view can also be dequeued for a pin that never pops.
        alpha = 1
        transform = .identity
        // Note: `clusteringIdentifier` is deliberately NOT touched here — clearing
        // it would drop the view from clustering until re-set. It's re-asserted
        // in `prepareForDisplay()` before the view is shown again.
        onReuse?()
        onReuse = nil
        endVideoPreview()
        imageTask?.cancel()
        imageTask = nil
        representedID = nil
        card.imageView.image = nil
        playBadge.isHidden = true
    }
}
