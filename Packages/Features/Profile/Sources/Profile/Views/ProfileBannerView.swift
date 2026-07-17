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

    init(imagePipeline: ImagePipeline) {
        self.imagePipeline = imagePipeline
        super.init(frame: .zero)
        clipsToBounds = true
        // Neutral backdrop while media loads (or when the profile has none):
        // the fade blends it into the page, so "no banner" degrades quietly.
        backgroundColor = .secondarySystemBackground

        mediaContainer.pin(to: self)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.pin(to: mediaContainer)

        // The identity block starts a full banner-clearance below the chrome
        // (~55% of the banner's height), so raw media owns the upper half and
        // the fade is near-opaque by the time the name lines begin.
        bottomFade.locations = [0.28, 0.55, 0.76, 1]
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
        }
    }

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
        CATransaction.commit()
    }

    /// CGColors don't track trait changes; re-resolve on style flips.
    private func refreshGradientColors() {
        let background = UIColor.systemBackground
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
