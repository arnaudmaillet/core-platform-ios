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
        // The picture reaches ABOVE the banner by the most the parallax can
        // carry it down, so lagging behind the content never uncovers the
        // banner's floor at the top — see `setTravelled`.
        imageView.translatesAutoresizingMaskIntoConstraints = false
        mediaContainer.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: mediaContainer.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: mediaContainer.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: mediaContainer.topAnchor, constant: -Self.parallaxReserve),
            imageView.bottomAnchor.constraint(equalTo: mediaContainer.bottomAnchor)
        ])

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

    /// Dresses the banner for a shape: the run-out's colours differ — a
    /// band's is a short, light softening of its edge; a poster's carries
    /// the identity and never quite hides the picture.
    func setFormat(_ format: ProfileBannerFormat) {
        guard format != self.format else { return }
        self.format = format
        refreshGradientColors()
        setNeedsLayout()
    }

    /// How much slower than the content the picture climbs: it keeps this
    /// share of the travel, so the identity block slides up OVER it rather
    /// than the two moving as one flat sheet.
    static let parallaxShare: CGFloat = 0.4
    /// How far the parallax may carry the picture down before it would
    /// uncover the banner's top — the picture is given this much extra
    /// height above the banner. 200pt of travel is more than either shape
    /// stays on screen for.
    static let parallaxReserve: CGFloat = 80

    /// The scroll, as the picture experiences it: it lags the content by
    /// `parallaxShare`, and a poster fades on the way — gone entirely by
    /// `fadeOutTravel`, the point at which the avatar's top reaches where a
    /// band would have put it, under the chrome. Nothing on a pull down: the
    /// stretch there is the banner's own.
    func setTravelled(_ travelled: CGFloat, fadeOutTravel: CGFloat) {
        let climb = max(0, travelled)
        imageView.transform = CGAffineTransform(
            translationX: 0, y: min(climb * Self.parallaxShare, Self.parallaxReserve)
        )
        guard format == .poster, fadeOutTravel > 0 else {
            alpha = 1
            return
        }
        alpha = max(0, 1 - climb / fadeOutTravel)
    }

    /// How far above a band's edge its softening begins.
    static let bandFadeDepth: CGFloat = 56
    /// How much of the page's tone a band's edge reaches: a softening, not a
    /// run-out — the edge is still an edge, the avatar's ring still cuts it.
    static let bandFadeAlpha: CGFloat = 0.5
    /// The poster's run-out at the counters and just above its foot. Neither
    /// is opaque: the picture shows through to the tray, faintly, so the
    /// poster reads as running the whole way down — while the page's tone is
    /// strong enough under every line of type for it to stay page ink on
    /// page colour. The very foot IS opaque, over `posterFootDepth`, so the
    /// banner's edge meets the page without a seam.
    static let posterFadeAtCounters: CGFloat = 0.75
    static let posterFadeNearFoot: CGFloat = 0.92
    static let posterFootDepth: CGFloat = 40
    /// How many segments the run-out's climb from clear to the counters is
    /// sampled in. The climb is a CURVE, not a line — see `posterClimb`.
    static let posterClimbSamples = 4

    /// The run-out's opacity at `t` of the way from its start to the
    /// counters, as a share of `posterFadeAtCounters`.
    ///
    /// Eased IN: gentle at the top, steeper at the bottom. A linear ramp put
    /// as much of the page's tone over the picture's upper half as over
    /// its lower, so the poster started greying the moment the run-out
    /// began; a square, tried next, held the tone back too long and then
    /// dumped it. This sits between the two — `t^1.5` — so the first half
    /// of the climb spends about a third of the tone.
    static let posterClimbExponent: CGFloat = 1.5
    static func posterClimb(_ t: CGFloat) -> CGFloat {
        let t = max(0, min(t, 1))
        return pow(t, posterClimbExponent)
    }

    /// The poster's stops, as (location, alpha) pairs, for a banner of
    /// `height` whose run-out starts at `start` and reaches the counters at
    /// `counters` — both in points from the top.
    static func posterStops(height: CGFloat, start: CGFloat, counters: CGFloat) -> [(CGFloat, CGFloat)] {
        let startFraction = max(0, min(start / height, 1))
        let countersFraction = max(startFraction, min(counters / height, 1))
        let nearFoot = max(countersFraction, (height - posterFootDepth) / height)
        var stops: [(CGFloat, CGFloat)] = []
        for sample in 0...posterClimbSamples {
            let t = CGFloat(sample) / CGFloat(posterClimbSamples)
            stops.append((
                startFraction + (countersFraction - startFraction) * t,
                posterFadeAtCounters * posterClimb(t)
            ))
        }
        stops.append((nearFoot, posterFadeNearFoot))
        stops.append((1, 1))
        return stops
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
    /// The run-out's opacity at each stop.
    var debugFadeAlphas: [CGFloat] {
        (bottomFade.colors as? [CGColor] ?? []).map { $0.alpha }
    }
    var debugShowsFade: Bool { !bottomFade.isHidden }
    /// How far the picture has been carried down by the parallax.
    var debugPictureShift: CGFloat { imageView.transform.ty }
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
        let height = bounds.height
        switch format {
        case .band:
            // A short softening of the strip's edge, and nothing above it.
            if height > 0 {
                let start = max(0, (height - Self.bandFadeDepth) / height)
                bottomFade.locations = [NSNumber(value: Double(start)), 1]
            }
        case .poster:
            // The run-out, placed in POINTS and converted here: clear until
            // it starts, most of the way by the counters, and strongest at
            // the foot — never quite hiding the picture, which runs under
            // the tray.
            if height > 0, fadeOpaque > fadeStart {
                let stops = Self.posterStops(height: height, start: fadeStart, counters: fadeOpaque)
                bottomFade.locations = stops.map { NSNumber(value: Double($0.0)) }
                let background = Surface.page
                bottomFade.colors = stops.map { background.withAlphaComponent($0.1).cgColor }
            }
        }
        CATransaction.commit()
    }

    /// CGColors don't track trait changes; re-resolve on style flips.
    private func refreshGradientColors() {
        // The PAGE's tone, not `systemBackground`: the fade has to land on
        // what the identity block actually sits on, or it ends in a lighter
        // band the width of the screen.
        let background = Surface.page
        switch format {
        case .band:
            bottomFade.colors = [
                background.withAlphaComponent(0).cgColor,
                background.withAlphaComponent(Self.bandFadeAlpha).cgColor
            ]
        case .poster:
            // Provisional until layout places the stops from the column's
            // frames — the same shape, at a guessed height.
            let stops = Self.posterStops(height: 600, start: 260, counters: 400)
            bottomFade.colors = stops.map { background.withAlphaComponent($0.1).cgColor }
            bottomFade.locations = stops.map { NSNumber(value: Double($0.0)) }
        }
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
