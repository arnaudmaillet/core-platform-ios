import CoreModels
import MapKit
import MediaCore
import MediaPlayback
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
final class MapClusterAnnotationView: MKAnnotationView, MapVideoHost {
    static let reuseIdentifier = "MapClusterAnnotationView"
    /// Match the individual pin exactly.
    private static let side = MapAnnotationView.side

    /// The cluster's face; also the exact blueprint of the flying card.
    let card = PinCardView(frame: CGRect(x: 0, y: 0, width: side, height: side))
    private var imageTask: Task<Void, Never>?
    /// Guards a slow load against reuse (clusters have no stable id, so key on
    /// the URL being shown).
    private var representedURL: URL?
    /// The face currently worn. Tracked separately because `representedURL` is
    /// `nil` for EVERY text representative: keying idempotence on the URL alone
    /// would read "already showing that" when the cluster had in fact just
    /// swapped between a text representative and a cover-less media one.
    private var representedFace: PinCardView.Face?
    /// The author face this marker is showing — part of the idempotence key,
    /// because a text cluster's URL and face cannot tell two groups apart.
    private var representedAvatar: URL?
    private var representedIcon: String?
    private var iconCatalog: AnimatedIconCatalog?
    private var previewCatalog: AnimatedIconCatalog?
    private var representedPreview: String?
    private var previewTask: Task<Void, Never>?
    /// The icon fetch, held apart from `imageTask` because an icon-led group now
    /// loads its icon AND the representative's avatar underneath it — the floor
    /// the card falls back to when the artwork never lands. One handle for both
    /// would let whichever resolved second cancel the first.
    private var iconTask: Task<Void, Never>?

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
    /// The ONE place icon artwork is put on the card.
    ///
    /// ⚠️ The shadow lives on THIS view's layer, not on the card, so the card
    /// cannot keep it honest by itself — and the art arrives on the other side
    /// of `applyFace`. A pin faces (shadow computed) and only then strips and
    /// re-dresses the icon; reading `card.wornIcon` inside `applyFace` therefore
    /// reads the RECYCLED view's previous art and is never revisited when the
    /// real art lands. Routing every write through here is what makes "no
    /// shadow under an icon, the text marker's lift under a bare one" true at
    /// every instant rather than at one.
    func applyIconArt(_ art: (art: AnimatedIconArt, phase: Int)?) {
        card.setIcon(art)
        PinCardView.applyPinShadow(to: layer, face: card.face, hasArt: art != nil)
    }

    private func applyFace(_ face: PinCardView.Face) {
        // Recycled across faces, like the pin's — see the note there.
        PinCardView.applyPinShadow(to: layer, face: face, hasArt: card.wornIcon != nil)
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
    func configure(
        with cluster: MapComputedCluster, imagePipeline: ImagePipeline,
        iconCatalog: AnimatedIconCatalog? = nil, previewCatalog: AnimatedIconCatalog? = nil
    ) {
        self.iconCatalog = iconCatalog
        self.previewCatalog = previewCatalog
        let url = cluster.representative.thumbnailURL
        let face = PinCardView.Face.of(cluster.representative)
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
        #if DEBUG
        applyDebugBandingBorder(for: kind)
        #endif
        // Idempotent: a tracked cluster is re-configured on every reconcile even
        // when its face is unchanged (same representative thumbnail). Blanking
        // and re-fetching it then would flash the card, so leave it be.
        // ⚠️ THE AVATAR IS PART OF THE KEY. A text cluster's cover URL is nil
        // and its face is always `.text`, so two groups led by DIFFERENT
        // authors compare equal on the pair above — and the second would keep
        // the first one's face for as long as the view survived.
        let avatar = cluster.representative.authorAvatarURL
        // ⚠️ THE ICON IS PART OF THE KEY, for exactly the reason the avatar is.
        // A text cluster's cover URL is nil and its face is `.icon` for every
        // icon-led group, so two groups led by DIFFERENT icons compare equal on
        // everything above — and the second would keep the first one's artwork
        // for as long as the view survived. The same bug, one field later.
        let icon = cluster.representative.animatedIconID
        // A media group's face is a post with footage, so it can preview too —
        // and the id is part of the key for the same reason the icon and the
        // avatar are: two groups led by different clips are not the same face.
        let preview = cluster.representative.previewSheetID
        #if DEBUG
        if representedURL == url && representedFace == face
            && representedAvatar == avatar && representedIcon == icon
            && representedPreview == preview {
            MapChurnCounters.skipped += 1
        } else {
            MapChurnCounters.bound += 1
        }
        #endif
        guard representedURL != url || representedFace != face
            || representedAvatar != avatar || representedIcon != icon
            || representedPreview != preview
        else { return }
        imageTask?.cancel()
        representedURL = url
        representedFace = face
        representedAvatar = avatar
        representedIcon = icon
        representedPreview = preview
        previewTask?.cancel()
        iconTask?.cancel()
        card.setPreviewSheet(nil)
        card.imageView.image = nil
        card.setTextAvatar(nil)
        applyIconArt(nil)
        applyFace(face)

        // A group led by an icon post wears that icon — the same representative
        // whose thumbnail a media group would show.
        if face == .icon, let iconCatalog, let icon {
            let phase = cluster.representative.iconPhase
            if let art = iconCatalog.cached(icon) {
                // In hand: the floor is never seen, so spend nothing on it.
                applyIconArt((art, phase))
                return
            }
            iconTask = Task { [weak self] in
                guard let art = try? await iconCatalog.art(for: icon) else { return }
                guard let self, self.representedIcon == icon else { return }
                self.applyIconArt((art, phase))
            }
            // No `return`: fall through to the avatar load, which dresses the
            // FLOOR under an icon that has not arrived — and may never.
        }
        // A text group wears the face of the post that leads it — the same
        // representative whose thumbnail a media group would show.
        //
        // ⚠️ Not `face == .text` any more. An icon-led group is a group of TEXT
        // posts, and its representative has an author like any other; gating on
        // the face meant the one face that can end up bare was the one face that
        // never loaded anything to be bare with.
        if face == .text || face == .icon, let avatar {
            imageTask = Task { [weak self] in
                guard let image = try? await imagePipeline.image(for: avatar) else { return }
                guard let self, self.representedAvatar == avatar else { return }
                self.card.setTextAvatar(image)
            }
            return
        }
        if face == .media, let previewCatalog, let preview {
            let phase = cluster.representative.iconPhase
            if let art = previewCatalog.cached(preview) {
                card.setPreviewSheet((art, phase))
            } else {
                previewTask = Task { [weak self] in
                    guard let art = try? await previewCatalog.art(for: preview) else { return }
                    guard let self, self.representedPreview == preview else { return }
                    self.card.setPreviewSheet((art, phase))
                }
            }
        }
        guard face == .media, let url else { return }
        imageTask = Task { [weak self] in
            guard let image = try? await imagePipeline.image(for: url) else { return }
            guard let self, self.representedURL == url else { return }
            self.card.imageView.image = image
        }
    }

    #if DEBUG
    var wearsAnimatedIcon: Bool { card.wornIcon != nil }
    var presentedIconTick: Double? { card.presentedIconTick }
    var presentedPreviewTick: Double? { card.presentedPreviewTick }
    var isPlayingPreviewSheet: Bool { card.isPlayingPreviewSheet }
    #endif

    /// See `MapAnnotationView.redressIcon`.
    func redressIcon() {
        card.reinstallIconPlayback()
        card.reinstallPreviewPlayback()
    }

    /// The live-preview surface. A cluster's face is one of its members' posts,
    /// so when that post is a video the group shows the same moving preview a
    /// lone pin would.
    var videoRenderView: VideoRenderView { card.videoRenderView }

    /// See `MapVideoHost`. Same two methods as the lone pin's, over the same
    /// `PinCardView` — the surface was always here; nothing could reach it.
    func beginVideoPreview() {
        card.videoRenderView.setPoster(card.imageView.image)
        card.videoRenderView.isHidden = false
    }

    func endVideoPreview() {
        card.videoRenderView.isHidden = true
        card.videoRenderView.setPoster(nil)
    }

    /// Invoked when MapKit recycles this view, so the coordinator can return a
    /// bound player to the pool before it is reused for another group.
    var onReuse: (() -> Void)?

    override func prepareForReuse() {
        super.prepareForReuse()
        // ⚠️ BEFORE the rest: the coordinator has to hand its player back while
        // this view still owns the surface. Clearing state first would leave a
        // player bound to a view that is about to draw a different group.
        onReuse?()
        onReuse = nil
        endVideoPreview()
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
        representedAvatar = nil
        representedIcon = nil
        representedPreview = nil
        previewTask?.cancel()
        previewTask = nil
        applyIconArt(nil)
        card.setPreviewSheet(nil)
        card.imageView.image = nil
        card.setTextAvatar(nil)
        card.setRing(color: MapMarkerRing.color(for: nil), width: MapMarkerRing.width(for: nil))
        #if DEBUG
        applyDebugBandingBorder(for: nil)
        #endif
        applyFace(.media)
    }

    #if DEBUG
    /// DEBUG-ONLY banding verifier, compiled out of release builds: a square
    /// outline on this outer view — blue for a COUNTRY cluster, red for a
    /// CITY one — so a screenshot says which band produced every marker.
    /// Deliberately square (the product ring is rounded, on the card) and on
    /// a separate layer, so the two never mix; a color that doesn't follow
    /// trait changes is fine for a diagnostic. `nil` (a generic cluster)
    /// wears no debug border.
    private func applyDebugBandingBorder(for kind: MapPlace.Kind?) {
        switch kind {
        case .country:
            layer.borderColor = UIColor.systemBlue.cgColor
            layer.borderWidth = 2
        case .city:
            layer.borderColor = UIColor.systemRed.cgColor
            layer.borderWidth = 2
        case nil:
            layer.borderColor = nil
            layer.borderWidth = 0
        }
    }
    #endif
}
