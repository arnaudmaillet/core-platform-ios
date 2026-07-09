import CoreModels
import MapKit
import MediaCore
import MediaPlayback
import UIKit

/// A custom pin: the post's `thumbnail_url` rendered as a small rounded square
/// on the map surface (UX req #1), with a downward tail so it points at its
/// coordinate. A play badge overlays video pins — dormant today because the
/// Radar path carries no media kind yet (see `GeoDiscoveryRepository`), and it
/// lights up automatically once field 5 lands.
///
/// The `VideoRenderView` live-preview pool (UX req #2) attaches here in Step B;
/// this Step A view is the still-thumbnail seam it plugs into.
final class MapAnnotationView: MKAnnotationView {
    static let reuseIdentifier = "MapAnnotationView"

    private static let side: CGFloat = 56
    private static let tailHeight: CGFloat = 8

    private let thumbnailView = UIImageView()
    /// Live-preview surface, overlaid on the thumbnail and shown only while this
    /// pin is one of the ≤3 the `MapVideoPlaybackCoordinator` has chosen to play.
    let videoRenderView = VideoRenderView()
    private let playBadge = UIImageView()
    private var imageTask: Task<Void, Never>?
    /// Guards against a slow image load landing on a recycled view.
    private var representedID: PostID?

    /// Set by the view controller so the view can fetch its own thumbnail.
    var imagePipeline: ImagePipeline?

    /// The loaded cover image, handed to the hero transition to fly.
    var heroImage: UIImage? { thumbnailView.image }

    /// Invoked when MapKit recycles this view, so the coordinator can return any
    /// player bound to it to the pool before it's reused for another pin.
    var onReuse: (() -> Void)?

    /// Reveals the live-preview surface over the thumbnail (playback is attached
    /// by the coordinator via `videoRenderView`). Seeds the render view's poster
    /// with the already-loaded thumbnail so the pin shows the still image — not a
    /// black frame — until the clip's first frame is ready.
    func beginVideoPreview() {
        videoRenderView.setPoster(thumbnailView.image)
        videoRenderView.isHidden = false
    }

    /// Hides the preview and clears it back to the still thumbnail.
    func endVideoPreview() {
        videoRenderView.isHidden = true
        videoRenderView.setPoster(nil)
    }

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        clusteringIdentifier = MapAnnotation.clusteringIdentifier
        // Anchor the marker so the tail tip sits on the coordinate.
        frame = CGRect(x: 0, y: 0, width: Self.side, height: Self.side + Self.tailHeight)
        centerOffset = CGPoint(x: 0, y: -(Self.side + Self.tailHeight) / 2)
        backgroundColor = .clear
        buildLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildLayout() {
        thumbnailView.contentMode = .scaleAspectFill
        thumbnailView.clipsToBounds = true
        thumbnailView.backgroundColor = UIColor.secondarySystemBackground
        thumbnailView.layer.cornerRadius = 12
        thumbnailView.layer.cornerCurve = .continuous
        thumbnailView.layer.borderWidth = 2
        thumbnailView.layer.borderColor = UIColor.systemBackground.cgColor
        thumbnailView.frame = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
        addSubview(thumbnailView)

        videoRenderView.frame = thumbnailView.frame
        videoRenderView.clipsToBounds = true
        videoRenderView.layer.cornerRadius = 12
        videoRenderView.layer.cornerCurve = .continuous
        videoRenderView.isHidden = true
        addSubview(videoRenderView)

        // A soft drop shadow lifts the pin off the map tiles.
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 2)

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
        thumbnailView.image = nil
        guard let url = pin.thumbnailURL else { return }
        let id = pin.postID
        imageTask = Task { [weak self] in
            guard let image = try? await imagePipeline.image(for: url) else { return }
            guard let self, self.representedID == id else { return }
            self.thumbnailView.image = image
            // If a live preview started before the thumbnail finished loading,
            // give it a poster now so the pin shows the still until the first
            // video frame — instead of a black square.
            if !self.videoRenderView.isHidden {
                self.videoRenderView.setPoster(image)
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onReuse?()
        onReuse = nil
        endVideoPreview()
        imageTask?.cancel()
        imageTask = nil
        representedID = nil
        thumbnailView.image = nil
        playBadge.isHidden = true
    }
}
