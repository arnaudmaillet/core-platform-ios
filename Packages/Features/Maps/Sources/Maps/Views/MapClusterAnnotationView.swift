import CoreModels
import MapKit
import MediaCore
import UIKit

/// A cluster of overlapping / co-located pins, rendered to look exactly like a
/// single post pin: the same rounded, center-anchored square showing its
/// representative's `thumbnail_url` — or the smaller symbol circle, when that
/// representative is a text post. The representative is kind-neutral (the
/// lowest id), so a group holding both wears whichever its first post is.
/// MapKit's default count bubble is deliberately not used. Its tap opens a snap feed seeded with all the cluster's member post
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
    /// The face currently worn. Tracked separately because `representedURL` is
    /// `nil` for EVERY text representative: keying idempotence on the URL alone
    /// would read "already showing that" when the cluster had in fact just
    /// swapped between a text representative and a cover-less media one.
    private var representedFace: PinCardView.Face?

    /// The loaded cover image, handed to the hero transition to fly.
    var heroImage: UIImage? { card.imageView.image }

    /// Fired the instant the cluster is tapped — see `installInstantTap`.
    var onSelect: (() -> Void)?

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        // Square collision + center anchoring, identical to a single pin.
        // No `clusteringIdentifier`: `MapClusterEngine` does the grouping, so
        // MapKit must not run its own clustering pass over these markers.
        collisionMode = .rectangle
        frame = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
        centerOffset = .zero
        backgroundColor = .clear

        addSubview(card)
        // The card clips, so the shadow lives on this outer layer — same as
        // the single pin.
        PinCardView.applyPinShadow(to: layer)
        installInstantTap(target: self, action: #selector(handleTap))
        applyFace(.media)
    }

    /// Wears `face`: its shape AND its size, exactly as a single pin does — an
    /// all-text group is a 44pt circle, so a cluster is never a different
    /// object from the markers it stands for. `bounds`, not `frame`: MapKit
    /// owns the center.
    private func applyFace(_ face: PinCardView.Face) {
        if bounds.width != face.side {
            bounds = CGRect(x: 0, y: 0, width: face.side, height: face.side)
        }
        card.frame = bounds
        card.setFace(face)
    }

    @objc private func handleTap() { onSelect?() }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Renders the representative post's thumbnail — the cluster's face and the
    /// image the hero transition flies. Called from the map delegate, which
    /// owns the image pipeline.
    func configure(with cluster: MapComputedCluster, imagePipeline: ImagePipeline) {
        let url = cluster.representative.thumbnailURL
        let face: PinCardView.Face = cluster.representative.isText ? .text : .media
        // The hierarchy ring, ABOVE the idempotence guard: a reconcile can
        // change the marker's level (a re-layout that gains or loses the
        // shared place) while the representative — and so the face and URL —
        // stays put. Re-applying an unchanged ring is a cheap set; missing a
        // level change leaves the wrong color on a live marker. Only the
        // active band's OWN markers wear a color: a local-band proximity
        // cluster sharing a leaf place keeps its gallery tap but dresses
        // neutral.
        let kind = cluster.isHierarchyMarker ? cluster.place?.kind : nil
        card.setRing(color: MapMarkerRing.color(for: kind), width: MapMarkerRing.width(for: kind))
        // Idempotent: a tracked cluster is re-configured on every reconcile even
        // when its face is unchanged (same representative thumbnail). Blanking
        // and re-fetching it then would flash the card, so leave it be.
        guard representedURL != url || representedFace != face else { return }
        imageTask?.cancel()
        representedURL = url
        representedFace = face
        card.imageView.image = nil
        applyFace(face)
        guard face == .media, let url else { return }
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
        onSelect = nil
        imageTask?.cancel()
        imageTask = nil
        representedURL = nil
        representedFace = nil
        card.imageView.image = nil
        card.setRing(color: MapMarkerRing.color(for: nil), width: MapMarkerRing.width(for: nil))
        applyFace(.media)
    }
}
