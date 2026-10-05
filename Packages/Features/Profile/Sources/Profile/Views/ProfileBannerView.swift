import DesignSystem
import MediaCore
import UIKit

/// The immersive media backdrop behind the profile identity block. It runs
/// from the absolute top of the screen (under the status bar and the
/// transparent navigation bar) down to the avatar's midline on a band, to the
/// tray's foot on a poster; the header lays its content on top of it.
///
/// Over the picture, bottom to top:
/// - `HeroBannerFade`: from just above the avatar, the page's tone climbs
///   the picture (the ramp) and the picture grows progressively blurred,
///   whole at the foot. The blur is barely there under the name — which
///   stands on it in the picture's ink (`HeroInk`) — and so is the page's
///   tone on a band; on a poster it is already half there (shouldered). The
///   same run-out as a place's banner;
/// - a subtle top scrim, so the status bar and navigation title survive a
///   bright sky.
///
/// `mediaContainer` hosts exactly one media surface. Today that is an image
/// fed through `ImagePipeline`; a video banner would drop a `VideoRenderView`
/// (MediaPlayback) into the same slot — and would need a live blur, since
/// `HeroBannerPictureView` bakes its blur from a still.
final class ProfileBannerView: UIView {
    private let mediaContainer = UIView()
    private let picture = HeroBannerPictureView()
    /// Over the media (and a loading bone), in this view's coordinates.
    private let ramp = HeroBannerRampView()
    private let topScrim = CAGradientLayer()
    /// The page's tone over everything above, at `1 - visibility`: how a
    /// poster fades away on the way up (`setTravelled`).
    ///
    /// ⚠️ A VEIL, NOT THE VIEW'S ALPHA. A view's partial alpha over a
    /// subtree is group opacity — the picture, its blur, the ramp and the
    /// scrim flattened OFFSCREEN, then faded, on every frame of the scroll
    /// that fades it. The page's tone laid over at the complement is the
    /// same picture, because what stands behind the banner is the page
    /// (the controller's view; the gallery under the header is clear), and
    /// it is one flat layer.
    private let veil = UIView()
    /// How much of the banner shows: 1 at rest; a poster's falls to 0 as it
    /// scrolls away. What the type's ink follows (`ProfileHeaderView`).
    private(set) var visibility: CGFloat = 1
    /// How far down the top scrim reaches — the chrome's own height, set by
    /// the header (`chromeTopInset`).
    ///
    /// ⚠️ NOT A FIXED 160pt. On a band the name starts 12pt under the
    /// chrome, and a 160pt scrim laid a sliver of black veil over it: the
    /// name measured 4.30:1 over a busy picture (the unit suite's stripes),
    /// over 4.5 once the scrim stops at the chrome.
    var topScrimHeight: CGFloat = 160 {
        didSet { if topScrimHeight != oldValue { setNeedsLayout() } }
    }

    private let imagePipeline: ImagePipeline
    private var imageTask: Task<Void, Never>?
    private var currentImageURL: URL?
    /// The picture that landed, whatever its route — from the cache before
    /// the first layout, or from a fetch afterwards — so the header can read
    /// its shape off it. See `ProfileBannerFormat`.
    var onImageResolved: ((UIImage) -> Void)?
    /// Whether the picture has stopped changing: drawn, absent, or failed —
    /// anything but a fetch still on its way. The screen holds its push on it
    /// (`ProfileViewController.isSettledForPresentation`), so the shape and
    /// the picture a viewer first sees are the ones that stay.
    private(set) var isPictureSettled = true
    /// Fires when `isPictureSettled` becomes true after a fetch.
    var onPictureSettled: (() -> Void)?
    /// The shape the banner is drawn in — which decides whether it fades out
    /// on the way up (a poster does, a band does not).
    private var format: ProfileBannerFormat = .unresolved

    init(imagePipeline: ImagePipeline) {
        self.imagePipeline = imagePipeline
        super.init(frame: .zero)
        clipsToBounds = true
        // Neutral backdrop while media loads (or when the profile has none):
        // the ramp blends it into the page, so "no banner" degrades quietly.
        backgroundColor = Surface.card

        mediaContainer.pin(to: self)
        // The picture reaches ABOVE the banner by the most the parallax can
        // carry it down, so lagging behind the content never uncovers the
        // banner's floor at the top — see `setTravelled`.
        picture.pictureOutset.top = Self.parallaxReserve
        picture.pin(to: mediaContainer)
        ramp.pin(to: self)

        topScrim.locations = [0, 1]
        topScrim.colors = [
            UIColor.black.withAlphaComponent(0.35).cgColor,
            UIColor.black.withAlphaComponent(0).cgColor
        ]
        layer.addSublayer(topScrim)

        // Over the scrim too: the veil fades the whole banner, as the
        // view's alpha did.
        veil.backgroundColor = Surface.page
        veil.isUserInteractionEnabled = false
        veil.isHidden = true
        veil.pin(to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        imageTask?.cancel()
    }

    func setImageURL(_ url: URL?) {
        guard url != currentImageURL || picture.image == nil else { return }
        currentImageURL = url
        imageTask?.cancel()
        picture.image = nil

        isPictureSettled = true
        guard let url else { return }
        let pipeline = imagePipeline
        // Synchronously from the cache when it can: the shape is read off the
        // picture, and a shape decided before the first layout is a header
        // that never jumps. A fetch still decides it, one layout later.
        if let cached = pipeline.cachedImage(for: url) {
            picture.image = cached
            onImageResolved?(cached)
            return
        }
        isPictureSettled = false
        imageTask = Task { [weak self] in
            let image = try? await pipeline.image(for: url)
            guard let self, !Task.isCancelled, self.currentImageURL == url else { return }
            // A failure settles too: the backdrop is what stays.
            defer {
                self.isPictureSettled = true
                self.onPictureSettled?()
            }
            guard let image else { return }
            // A full-bleed surface landing abruptly is the loudest pop on the
            // screen; dissolve it over the neutral backdrop.
            UIView.transition(
                with: self.picture, duration: 0.25,
                options: [.transitionCrossDissolve, .allowUserInteraction]
            ) {
                self.picture.image = image
            }
            self.onImageResolved?(image)
        }
    }

    /// Adopts a shape: only a poster fades out on the way up.
    ///
    /// ⚠️ A BAND DOES NOT BLUR, AND ITS RAMP IS BLACK (user, 5 October 2026):
    /// the strip stays sharp to its foot, and the opacity ramp lands on
    /// black whatever the appearance rather than on the page's tone. The
    /// ground the name's ink is read off follows (`pageTone`). A poster keeps
    /// the progressive blur into the page's tone.
    func setFormat(_ format: ProfileBannerFormat) {
        self.format = format
        let band = format == .band
        picture.showsBlur = !band
        let tone: UIColor = band ? Self.bandRampTone : Surface.page
        ramp.tone = tone
        picture.pageTone = tone
    }

    /// The tone a band's ramp lands on: black, fixed.
    static let bandRampTone = UIColor.black

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
    /// `parallaxShare` — sliding UNDER the blur, which stays with the type —
    /// and a poster fades on the way, gone entirely by `fadeOutTravel`, the
    /// point at which the avatar's top reaches where a band would have put
    /// it, under the chrome. Nothing on a pull down: the stretch there is the
    /// banner's own.
    func setTravelled(_ travelled: CGFloat, fadeOutTravel: CGFloat) {
        let climb = max(0, travelled)
        picture.pictureShift = min(climb * Self.parallaxShare, Self.parallaxReserve)
        guard format == .poster, fadeOutTravel > 0 else { return setVisibility(1) }
        setVisibility(max(0, 1 - climb / fadeOutTravel))
    }

    /// Shows `value` of the banner: the veil at the complement in between;
    /// at nothing, the view is not drawn at all (alpha 0 skips its tree).
    private func setVisibility(_ value: CGFloat) {
        guard value != visibility else { return }
        visibility = value
        alpha = value > 0 ? 1 : 0
        veil.alpha = 1 - value
        veil.isHidden = value >= 1 || value <= 0
    }

    /// Touches as the view's alpha gave them: a banner all but gone is not
    /// there to be touched.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        visibility < 0.01 ? nil : super.hitTest(point, with: event)
    }

    /// Called when the blurred picture changes — the moment to read the
    /// ground under the type again (`groundPixels(behind:)`).
    var onLevelsChanged: (() -> Void)? {
        get { picture.onLevelsChanged }
        set { picture.onLevelsChanged = newValue }
    }

    /// The blurred picture's pixels behind `rect`, in this view's
    /// coordinates AT REST — the header's own, since the banner rests on the
    /// header's top (the picture is pinned edge to edge) — see
    /// `HeroBannerPictureView.groundPixels(behind:)`.
    func groundPixels(behind rect: CGRect) -> [SIMD3<Float>]? {
        picture.groundPixels(behind: rect)
    }

    /// Where the picture blurs and where the page takes over, in this view's
    /// own points from its RESTING top (the header's) — set by the header
    /// from where the identity block actually landed. See `HeroBannerFade`.
    func setFade(_ fade: HeroBannerFade.Geometry) {
        picture.fade = fade
        ramp.fade = fade
    }

    #if DEBUG
    var debugHasPicture: Bool { picture.image != nil }
    var debugShowsBlur: Bool { picture.showsBlur }
    var debugRampTone: UIColor { ramp.tone }
    var debugFade: HeroBannerFade.Geometry? { picture.fade }
    var debugBlurLevels: [(start: CGFloat, full: CGFloat)] { picture.debugVisibleLevels }
    var debugRampLocations: [CGFloat] { ramp.debugLocations }
    var debugRampAlphas: [CGFloat] { ramp.debugAlphas }
    var debugLastBlurBakeMilliseconds: Double { picture.debugLastBakeMilliseconds }
    var debugLastBlurBakeBytes: Int { picture.debugLastBakeBytes }
    var debugBlurComposeCount: Int { picture.debugComposeCount }
    var debugBlurBakeCount: Int { picture.debugBakeCount }
    /// Where the sharp picture covers, in this view's space.
    var debugPictureCover: CGRect { picture.convert(picture.debugPictureCover, to: self) }
    var debugRampFrame: CGRect { ramp.convert(ramp.debugRampFrame, to: self) }
    /// How far the picture has been carried down by the parallax.
    var debugPictureShift: CGFloat { picture.pictureShift }
    #endif

    // MARK: - Redaction

    private var bone: SkeletonBoneView?

    /// Skeleton state: a shimmer sheet in the media slot, under the ramp —
    /// which dissolves it into the page exactly as it does real media, so the
    /// loading banner and the loaded one share every seam. Alpha-only, so a
    /// reveal inside an animation block cross-fades.
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
        // A pull-down stretches the banner ABOVE the header's top, where it
        // rests (`ProfileHeaderView.anchorBanner`): the picture and the ramp
        // keep their resting layout and only zoom — see
        // `HeroBannerPictureView`. Set here, before they lay out in this pass.
        let stretch = max(0, -frame.minY)
        picture.stretch = stretch
        ramp.stretch = stretch
        // Sublayer frames don't follow Auto Layout; keep them in step without
        // the implicit CALayer animation smearing during rotation/resize.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        topScrim.frame = CGRect(x: 0, y: 0, width: bounds.width, height: min(topScrimHeight, bounds.height))
        CATransaction.commit()
    }
}
