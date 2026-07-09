import CoreModels
import MapKit
import MediaCore
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
    private let playBadge = UIImageView()
    private var imageTask: Task<Void, Never>?
    /// Guards against a slow image load landing on a recycled view.
    private var representedID: PostID?

    /// Set by the view controller so the view can fetch its own thumbnail.
    var imagePipeline: ImagePipeline?

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
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageTask?.cancel()
        imageTask = nil
        representedID = nil
        thumbnailView.image = nil
        playBadge.isHidden = true
    }
}
