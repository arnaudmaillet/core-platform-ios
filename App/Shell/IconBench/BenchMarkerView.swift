#if DEBUG
import MapKit
import UIKit

/// A stand-in for `MapAnnotationView` wearing `PinCardView`'s text face, built
/// to the same dimensions and with the same layer structure, so what this screen
/// measures transfers.
///
/// Mirrored deliberately, not approximated:
/// - 44pt disc (`PinCardView.Face.text.side`), 132x132 px at @3x.
/// - The icon fills the WHOLE disc. It replaces the author avatar, and
///   `PinTextFaceView.avatar` is `frame = bounds` / `scaleAspectFill`. This is
///   not a badge, and sizing it like one would flatter every number here.
/// - The glyph underneath is what a marker shows when it has no icon — and, more
///   importantly, what it shows for the ~350ms its sheet is still loading. A
///   marker never goes blank.
/// - The soft shadow, which the real `PinCardView.applyPinShadow` sets WITHOUT a
///   `shadowPath`.
///
/// ## The two toggles that matter more than the icon itself
///
/// Today a marker's content never changes, so Core Animation caches its masked
/// composite and its blurred shadow once and just slides the result around as
/// MapKit pans. Both are effectively free. An animated icon changes contents
/// every frame and invalidates BOTH caches, on every marker, on every tick.
///
/// **The regression is the loss of the cache, not the arrival of the pass.**
///
/// So `usesShadowPath` and `masksOnCard` are not micro-optimisations bolted on
/// afterwards; they are the difference between a shippable feature and an
/// unshippable one, and this screen exists partly to measure by how much.
final class BenchMarkerView: MKAnnotationView {

    static let reuseIdentifier = "BenchMarkerView"

    /// `PinCardView.Face.text.side`.
    static let side: CGFloat = 44

    /// Explicit `shadowPath` versus the pathless shadow shipping today.
    ///
    /// `ZoomFlight` already does this correctly; `PinCardView.applyPinShadow`
    /// does not. Note the path must be re-set whenever bounds or corner radius
    /// change — in the real component `applyFace` flips between 56pt square and
    /// 44pt circle, so a path set once draws a square shadow behind a round
    /// marker after the first face change.
    static var usesShadowPath = true

    /// Puts the wasteful path back: `clipsToBounds` + `cornerRadius` on a card
    /// with several sibling subviews, which is the classic offscreen-mask case.
    ///
    /// With a circular alpha baked into the sheet the mask is redundant, which
    /// is why the backend doc asks for pre-rounded assets.
    static var masksOnCard = false

    /// The card: the real component's outer, non-clipping shadow host.
    private let card = UIView()
    private let glyph = UIImageView()
    /// The icon's own layer on the SHEET path. A bare `CALayer`, not a view —
    /// nothing here needs touch handling, Auto Layout or a responder, and 128 of
    /// those are not free.
    private let iconLayer = CALayer()

    /// The DECOMPOSED path's two layers.
    ///
    /// Two, not one, and the split is forced by the artwork: in the sheet the
    /// plate is fixed and only the mark moves inside it, so a single layer
    /// carrying the transform would pulse and spin the plate as well. The mark
    /// therefore gets its own layer above a plate that never moves.
    ///
    /// The honest cost of that: 256 composited quads instead of 128. On a TBDR
    /// GPU, at 44pt, that is noise — but it is not literally nothing, and it is
    /// the one place this path is more expensive than the sheet.
    ///
    /// The plate holds NO texture. A `backgroundColor` with a circular
    /// `cornerRadius` costs zero bytes of backing store, needs no mask and no
    /// offscreen pass, where the sheet re-records the same disc in full colour
    /// in every one of its 24 cells.
    private let plateLayer = CALayer()
    private let glyphLayer = CALayer()
    /// Cell fraction the plate is inset by, so the layer geometry reproduces the
    /// sheet's gutter exactly rather than approximately.
    private var plateInsetFraction: Double = 0

    private var iconID: Int?
    /// The frame this marker starts on. A pure function of its identity, so the
    /// hero flight card can reproduce it exactly by copying one `Int`.
    private var phase: Int = 0
    private var art: IconArt?
    private var loadTask: Task<Void, Never>?

    weak var store: IconAtlasStore?
    var mode: IconPlayback.Mode = .quantised
    var sampling: IconPlayback.Sampling = .stepped

    /// A fingerprint of what the RENDER SERVER is presenting right now, or `nil`
    /// if nothing is animating.
    ///
    /// Read from `presentation()`, not from the model layer — the model layer
    /// keeps its resting value for the whole animation, so probing it would
    /// report a frozen icon as a running one. This is how the screen answers
    /// "what rate are you ACTUALLY showing", which is a different question from
    /// "what rate did we ask for" and the only one worth trusting.
    ///
    /// It has to be a fingerprint rather than a `contentsRect` now that the
    /// recommended path does not touch `contentsRect` at all: probing that one
    /// property would have reported the decomposed field as motionless, which
    /// reads exactly like a broken animation and would have been believed.
    /// `m11`/`m12` carry scale and rotation, `opacity` the third channel, so one
    /// number covers every motion in the catalogue.
    var presentedTick: Double? {
        if iconLayer.animation(forKey: IconPlayback.animationKey) != nil {
            guard let rect = iconLayer.presentation()?.contentsRect else { return nil }
            return Double(rect.origin.x) * 4096 + Double(rect.origin.y)
        }
        guard IconPlayback.decomposedKeys.contains(where: { glyphLayer.animation(forKey: $0) != nil }),
              let presentation = glyphLayer.presentation()
        else { return nil }
        let transform = presentation.transform
        return Double(transform.m11) * 1e6 + Double(transform.m12) * 1e3 + Double(presentation.opacity)
    }

    /// Fired once per marker when its sheet lands, so the screen can report how
    /// long the cold field took to fully dress.
    var onIconResolved: (() -> Void)?

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)

        frame = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
        backgroundColor = .clear
        // Centred on its coordinate, like the real marker.
        centerOffset = .zero

        card.frame = bounds
        card.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        card.backgroundColor = .clear
        card.layer.cornerCurve = .continuous
        addSubview(card)

        glyph.image = UIImage(systemName: "text.bubble.fill")?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
        glyph.tintColor = .white
        glyph.contentMode = .center
        glyph.frame = bounds
        glyph.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        glyph.backgroundColor = .systemGray
        glyph.layer.cornerRadius = Self.side / 2
        glyph.layer.cornerCurve = .continuous
        glyph.clipsToBounds = true
        card.addSubview(glyph)

        // ABOVE the glyph, because it REPLACES it rather than decorating it —
        // the same relationship `PinTextFaceView` gives the avatar.
        iconLayer.frame = card.bounds
        iconLayer.contentsScale = UIScreen.main.scale
        iconLayer.isHidden = true
        card.layer.addSublayer(iconLayer)

        // SIBLINGS, not parent and child. Nesting the mark inside the plate
        // would scale it by the gutter fraction and make the decomposed glyph
        // 3% smaller than the sheet's — a difference small enough to look like
        // nothing and big enough to be a rendering defect.
        for layer in [plateLayer, glyphLayer] {
            layer.frame = card.bounds
            layer.contentsScale = UIScreen.main.scale
            layer.isHidden = true
            card.layer.addSublayer(layer)
        }

        applyChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Chrome

    /// Applies the shadow and mask policy. Re-invoked on bounds changes, which
    /// is the part `PinCardView` would have to get right too.
    func applyChrome() {
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.25
        card.layer.shadowRadius = 4
        card.layer.shadowOffset = CGSize(width: 0, height: 2)
        card.layer.shadowPath = Self.usesShadowPath
            ? UIBezierPath(ovalIn: card.bounds).cgPath
            : nil

        // The mask the pre-rounded asset makes unnecessary.
        card.clipsToBounds = Self.masksOnCard
        card.layer.cornerRadius = Self.masksOnCard ? Self.side / 2 : 0
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        iconLayer.frame = card.bounds
        glyphLayer.frame = card.bounds
        let inset = card.bounds.width * plateInsetFraction
        plateLayer.frame = card.bounds.insetBy(dx: inset, dy: inset)
        plateLayer.cornerRadius = plateLayer.bounds.width / 2
        applyChrome()
    }

    // MARK: - Binding

    /// Stores identity ONLY. Nothing is installed here.
    ///
    /// `MapAnnotationView.configure` early-returns on an unchanged
    /// `representedID`, so a surviving marker's reconfigure is a true no-op —
    /// and backgrounding STRIPS Core Animation animations. An animation
    /// installed from `configure` would therefore stay frozen forever on every
    /// marker that survived a background/foreground cycle. Installation belongs
    /// to `didMoveToWindow`, which is also the app's own shipped idiom
    /// (`SkeletonBoneView.reinstallIfVisible`).
    func bind(iconID: Int?, phase: Int) {
        guard self.iconID != iconID || self.phase != phase else { return }
        loadTask?.cancel()
        loadTask = nil
        art = nil
        undress()

        self.iconID = iconID
        self.phase = phase

        if window != nil { startIfNeeded() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            loadTask?.cancel()
            loadTask = nil
            IconPlayback.remove(from: iconLayer)
            IconPlayback.removeDecomposed(plate: plateLayer, glyph: glyphLayer)
        } else {
            startIfNeeded()
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        iconID = nil
        art = nil
        undress()
        alpha = 1
        transform = .identity
    }

    /// Puts every icon layer back to "nothing here", whichever path last dressed
    /// it.
    ///
    /// One call rather than a branch, because a reused marker does not remember
    /// which path dressed it — and a leftover `contents` under a decomposed
    /// dressing is a stale sheet showing through the plate, which looks like a
    /// texture-sharing bug and is not one.
    private func undress() {
        IconPlayback.remove(from: iconLayer)
        IconPlayback.removeDecomposed(plate: plateLayer, glyph: glyphLayer)
        [iconLayer, plateLayer, glyphLayer].forEach { $0.isHidden = true }
    }

    private func startIfNeeded() {
        guard let iconID, let store else { return }

        // Synchronous hit: dress immediately, with no flash of glyph. On a warm
        // field this is every marker, which is why the cold path is the one that
        // has to be watched.
        if let hit = store.cached(iconID) {
            apply(hit)
            return
        }

        guard loadTask == nil else { return }
        let wanted = iconID
        loadTask = Task { [weak self] in
            guard let self else { return }
            let resolved = try? await store.art(for: wanted)
            // The identity guard. A slow load must never land on a view MapKit
            // has since recycled onto a different marker — the same reason
            // `MapAnnotationView` keeps `representedID`.
            guard !Task.isCancelled, self.iconID == wanted, let resolved else { return }
            self.apply(resolved)
            self.onIconResolved?()
        }
    }

    private func apply(_ art: IconArt) {
        self.art = art
        loadTask = nil

        switch art {
        case .sheet(let atlas):
            plateLayer.isHidden = true
            glyphLayer.isHidden = true
            iconLayer.isHidden = false
            guard IconPlayback.motionAllowed else {
                // Static, not blank: the marker looks identical, it simply does
                // not move. Reduce Motion must not cost the viewer the icon.
                iconLayer.contents = atlas.sheet.cgImage
                iconLayer.contentsRect = atlas.frameRects[phase % atlas.frameCount]
                return
            }
            IconPlayback.install(atlas, phase: phase, mode: mode, on: iconLayer)

        case .decomposed(let still):
            iconLayer.isHidden = true
            plateInsetFraction = still.plateInsetFraction
            setNeedsLayout()
            layoutIfNeeded()
            plateLayer.isHidden = false
            glyphLayer.isHidden = false
            IconPlayback.install(
                still, phase: phase, mode: mode, sampling: sampling,
                plate: plateLayer, glyph: glyphLayer
            )
            guard !IconPlayback.motionAllowed else { return }
            // `install` already parked the model layer on the resting pose, so
            // stripping the animations here leaves the icon posed and static
            // rather than snapped to identity.
            IconPlayback.decomposedKeys.forEach { glyphLayer.removeAnimation(forKey: $0) }
        }
    }

    /// Re-installs after a foreground transition, which strips animations.
    func reinstallIfNeeded() {
        guard window != nil, let art else { return }
        switch art {
        case .sheet:
            guard iconLayer.animation(forKey: IconPlayback.animationKey) == nil else { return }
        case .decomposed:
            let running = IconPlayback.decomposedKeys.contains {
                glyphLayer.animation(forKey: $0) != nil
            }
            guard !running else { return }
        }
        apply(art)
    }

    func setFrozen(_ frozen: Bool) {
        guard let art else { return }
        switch (art, frozen) {
        case (.sheet, true):
            IconPlayback.freeze(iconLayer)
        case (.decomposed, true):
            IconPlayback.freezeDecomposed(glyph: glyphLayer)
        case (_, false):
            reinstallIfNeeded()
        }
    }
}
#endif
