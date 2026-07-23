import CoreModels
import MapKit
import MediaCore
import UIKit

/// A cluster of overlapping / co-located pins, rendered to look exactly like a
/// single post pin: the same rounded, center-anchored square showing the *first*
/// member post's `thumbnail_url`. MapKit's default count bubble is deliberately
/// not used. Its tap opens a snap feed seeded with all the cluster's member post
/// ids — already held client-side, so no extra round-trip.
///
/// The face is a `PinCardView` — the same component the single pin renders and
/// the hero transition flies — so pin, cluster, and flight card are twins by
/// construction, with no per-surface styling constants left to drift.
final class MapClusterAnnotationView: MKAnnotationView {
    static let reuseIdentifier = "MapClusterAnnotationView"
    /// Match the individual pin exactly.
    private static let side = MapAnnotationView.side

    /// The cluster's face; also the exact blueprint of the flying card.
    private let card = PinCardView(frame: CGRect(x: 0, y: 0, width: side, height: side))
    private var imageTask: Task<Void, Never>?
    /// Guards a slow load against reuse (clusters have no stable id, so key on
    /// the URL being shown).
    private var representedURL: URL?

    /// The loaded cover image, handed to the hero transition to fly.
    var heroImage: UIImage? { card.imageView.image }

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        // Square collision + center anchoring, identical to a single pin.
        collisionMode = .rectangle
        frame = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
        centerOffset = .zero
        backgroundColor = .clear
        // Share the pins' clustering identifier so clusters keep participating in
        // the clustering tree — they merge into larger clusters as you zoom out
        // instead of falling out of clustering entirely.
        clusteringIdentifier = MapAnnotation.clusteringIdentifier

        addSubview(card)
        // The card clips, so the shadow lives on this outer layer — same as
        // the single pin.
        PinCardView.applyPinShadow(to: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Re-assert the clustering identifier on every display, for the same
    /// reuse-consumption reason as `MapAnnotationView` — so a recycled cluster
    /// view never drops out of the clustering tree mid-zoom.
    override func prepareForDisplay() {
        super.prepareForDisplay()
        clusteringIdentifier = MapAnnotation.clusteringIdentifier
    }

    /// Renders the first member post's thumbnail. Called from the map delegate,
    /// which owns the image pipeline.
    func configure(with cluster: MKClusterAnnotation, imagePipeline: ImagePipeline) {
        let firstThumbnail = cluster.memberAnnotations
            .lazy
            .compactMap { ($0 as? MapAnnotation)?.pin.thumbnailURL }
            .first

        imageTask?.cancel()
        representedURL = firstThumbnail
        card.imageView.image = nil
        guard let url = firstThumbnail else { return }
        imageTask = Task { [weak self] in
            guard let image = try? await imagePipeline.image(for: url) else { return }
            guard let self, self.representedURL == url else { return }
            self.card.imageView.image = image
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        // Same reason as `MapAnnotationView`: pop state belongs to an
        // appearance, and a cluster view recycled mid-fade would otherwise
        // come back invisible and half-size.
        alpha = 1
        transform = .identity
        imageTask?.cancel()
        imageTask = nil
        representedURL = nil
        card.imageView.image = nil
    }
}
