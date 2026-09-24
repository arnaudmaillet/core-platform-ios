import DesignSystem
import MediaCore
import UIKit

/// The immersive media backdrop behind the profile identity block. It runs
/// from the absolute top of the screen (under the status bar and the
/// transparent navigation bar) down to the bottom of the action-button tray;
/// the header lays its content on top of it.
///
/// Two gradient layers make the overlay legible over arbitrary media:
/// - a bottom fade from clear into `systemBackground`, so the identity block's
///   standard `.label` text sits on (effectively) the page background in both
///   light and dark mode — in dark mode this *is* the fade-to-dark treatment;
/// - a subtle top scrim, so the status bar and navigation title survive a
///   bright sky.
///
/// `mediaContainer` hosts exactly one media surface. Today that is an image
/// fed through `ImagePipeline`; a video banner drops a `VideoRenderView`
/// (MediaPlayback) into the same slot without touching the gradient stack.
final class ProfileBannerView: UIView {
    private let mediaContainer = UIView()
    private let imageView = FillImageView()
    private let bottomFade = CAGradientLayer()
    private let topScrim = CAGradientLayer()

    private let imagePipeline: ImagePipeline
    private var imageTask: Task<Void, Never>?
    private var currentImageURL: URL?
    /// The picture that landed, whatever its route — from the cache before
    /// the first layout, or from a fetch afterwards — so the header can read
    /// its shape off it. See `ProfileBannerFormat`.
    var onImageResolved: ((UIImage) -> Void)?
    /// The shape the banner is drawn in. A band has no run-out at all: the
    /// picture ends on a clean edge the avatar's ring cuts across.
    private var format: ProfileBannerFormat = .unresolved
    /// Where the poster's run-out begins and where it is opaque, in this
    /// view's own points from its top — set by the header from where the
    /// identity block actually landed.
    private var fadeStart: CGFloat = 0
    private var fadeOpaque: CGFloat = 0

    init(imagePipeline: ImagePipeline) {
        self.imagePipeline = imagePipeline
        super.init(frame: .zero)
        clipsToBounds = true
        // Neutral backdrop while media loads (or when the profile has none):
        // the fade blends it into the page, so "no banner" degrades quietly.
        backgroundColor = Surface.card

        mediaContainer.pin(to: self)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.pin(to: mediaContainer)

        // Provisional until the header has laid its column out and says
        // where the run-out goes — see `setFade(start:opaque:)`.
        bottomFade.locations = [0.42, 0.55, 0.68, 1]
        topScrim.locations = [0, 1]
        layer.addSublayer(bottomFade)
        layer.addSublayer(topScrim)
        refreshGradientColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: ProfileBannerView, _) in
            self.refreshGradientColors()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        imageTask?.cancel()
    }

    func setImageURL(_ url: URL?) {
        guard url != currentImageURL || imageView.image == nil else { return }
        currentImageURL = url
        imageTask?.cancel()
        imageView.image = nil

        guard let url else { return }
        let pipeline = imagePipeline
        // Synchronously from the cache when it can: the shape is read off the
        // picture, and a shape decided before the first layout is a header
        // that never jumps. A fetch still decides it, one layout later.
        if let cached = pipeline.cachedImage(for: url) {
            imageView.image = cached
            onImageResolved?(cached)
            return
        }
        imageTask = Task { [weak self] in
            guard let image = try? await pipeline.image(for: url) else { return }
            guard let self, !Task.isCancelled, self.currentImageURL == url else { return }
            // A full-bleed surface landing abruptly is the loudest pop on the
            // screen; dissolve it over the neutral backdrop.
            UIView.transition(
                with: self.imageView, duration: 0.25,
                options: [.transitionCrossDissolve, .allowUserInteraction]
            ) {
                self.imageView.image = image
            }
            self.onImageResolved?(image)
        }
    }

    /// Dresses the banner for a shape. A band drops its run-out entirely.
    func setFormat(_ format: ProfileBannerFormat) {
        guard format != self.format else { return }
        self.format = format
        bottomFade.isHidden = format == .band
        setNeedsLayout()
    }

    /// Where the poster's run-out begins and where it is fully the page's
    /// tone, in this view's points from its top. The header sets both from
    /// where its identity block landed, so the picture stays untouched above
    /// the avatar and the counters always sit on solid page.
    func setFade(start: CGFloat, opaque: CGFloat) {
        guard start != fadeStart || opaque != fadeOpaque else { return }
        fadeStart = start
        fadeOpaque = opaque
        setNeedsLayout()
    }

    #if DEBUG
    /// The run-out's stops as fractions of the banner's height, for a test
    /// that asks where the picture is left alone.
    var debugFadeLocations: [CGFloat] { (bottomFade.locations ?? []).map { CGFloat($0.doubleValue) } }
    var debugShowsFade: Bool { !bottomFade.isHidden }
    #endif

    // MARK: - Redaction

    private var bone: SkeletonBoneView?

    /// Skeleton state: a shimmer sheet in the media slot, under the gradient
    /// stack — the bottom fade mutes it into the page exactly as it does real
    /// media, so the loading banner and the loaded one share every seam.
    /// Alpha-only, so a reveal inside an animation block cross-fades.
    func setRedacted(_ redacted: Bool) {
        if redacted, bone == nil {
            let bone = SkeletonBoneView(rounding: .fixed(0))
            bone.pin(to: mediaContainer)
            self.bone = bone
        }
        bone?.isHidden = false
        bone?.alpha = redacted ? 1 : 0
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Sublayer frames don't follow Auto Layout; keep them in step without
        // the implicit CALayer animation smearing during rotation/resize.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bottomFade.frame = bounds
        topScrim.frame = CGRect(x: 0, y: 0, width: bounds.width, height: min(160, bounds.height))
        // The run-out, placed in POINTS and converted here: clear until it
        // starts, most of the way by halfway, opaque at the counters, and
        // opaque to the edge — so the block from the counters down reads on
        // solid page while the name row alone sits on the fade.
        if format == .poster, bounds.height > 0, fadeOpaque > fadeStart {
            let height = bounds.height
            let start = max(0, min(fadeStart / height, 1))
            let opaque = max(start, min(fadeOpaque / height, 1))
            bottomFade.locations = [
                NSNumber(value: Double(start)),
                NSNumber(value: Double((start + opaque) / 2)),
                NSNumber(value: Double(opaque)),
                1
            ]
        }
        CATransaction.commit()
    }

    /// CGColors don't track trait changes; re-resolve on style flips.
    private func refreshGradientColors() {
        // The PAGE's tone, not `systemBackground`: the fade has to land on
        // what the identity block actually sits on, or it ends in a lighter
        // band the width of the screen.
        let background = Surface.page
        bottomFade.colors = [
            background.withAlphaComponent(0).cgColor,
            background.withAlphaComponent(0.85).cgColor,
            background.cgColor,
            background.cgColor
        ]
        topScrim.colors = [
            UIColor.black.withAlphaComponent(0.35).cgColor,
            UIColor.black.withAlphaComponent(0).cgColor
        ]
    }
}

/// An image view with no intrinsic size: the banner media is sized purely by
/// the banner's constraints (top of screen → action tray). A loaded bitmap's
/// intrinsic size must not vote, or it drags the banner — and, through the
/// bottom tie to the action row, the whole identity block — toward the
/// bitmap's pixel height.
private final class FillImageView: UIImageView {
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }
}
