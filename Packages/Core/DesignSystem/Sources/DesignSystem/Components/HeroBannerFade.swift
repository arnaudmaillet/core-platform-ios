import Accelerate
import UIKit

/// How a picture-led header's banner runs out into the page — a profile's
/// band or poster, a place's banner: the picture grows PROGRESSIVELY BLURRED
/// towards its foot, and only its last few points dissolve into the page's
/// tone.
///
/// ```
///   ┌──────────────────────────┐
///   │      ~~~ picture ~~~     │  sharp
///   │                          │ ── blurStart: 0%
///   │      ~≈~ picture ~≈~     │  blur climbs, slowly first (ease-in),
///   │ (◯)  Name                │  through the type…
///   │      @handle  ≈≈≈≈≈≈≈≈≈≈ │
///   │▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒│ ── rampStart … rampEnd: the page arrives
///   └──────────────────────────┘ ── blurFull: 100%, the banner's foot
///        35   12   3.5K           page ink on the page
/// ```
///
/// ⚠️ **A LONG OPACITY RAMP OVER A PHOTOGRAPH IS A HALO.** Both headers used
/// to run the picture out over a hundred-odd points of page tone: on a light
/// page that is a white wash climbing up the picture — the photograph looks
/// fogged, lit from below — and the user asked for it gone (30 September
/// 2026). The blur does the long transition instead: it takes the detail out
/// of the picture's foot without changing its colour, so the type standing
/// there has a calm ground, and the page's tone only has to cover a SHORT
/// seam, too short to read as a glow.
///
/// ⚠️ **THE BLUR IS BAKED FROM THE PICTURE, NOT A MATERIAL.** A
/// `UIVisualEffectView` under a gradient mask was the obvious public route,
/// and it is exactly the halo again: every `UIBlurEffect` style carries a
/// tint, white-ish on a light page, which is a frost over the picture's
/// foot. These levels are the picture itself, blurred once (vImage, 7–40ms on a
/// background queue) when it lands or when its displayed size changes — so they
/// keep the picture's own colours, cost nothing per frame beyond compositing
/// six masked layers, and render in `layer.render(in:)`, where the contrast
/// instrument (`HeroInk.debugContrast`) can see them. A VIDEO banner would
/// need a live blur instead; there is none today.
///
/// The progressive radius is approximated by stacking levels of increasing
/// sigma, each fading in over the stretch where the wanted sigma climbs from
/// the previous level's to its own — at any height at most two neighbouring
/// levels blend, which is what keeps the climb free of visible steps.
public enum HeroBannerFade {
    /// Where the fade runs, in the coordinates of the view it is handed to.
    public struct Geometry: Equatable, Sendable {
        /// Where the blur starts climbing from nothing — the top of its
        /// container.
        public var blurStart: CGFloat
        /// Where it reaches its strongest — the bottom of its container, the
        /// banner's foot.
        public var blurFull: CGFloat
        /// Where the page's tone starts arriving, and where it is opaque.
        public var rampStart: CGFloat
        public var rampEnd: CGFloat

        public init(blurStart: CGFloat, blurFull: CGFloat, rampStart: CGFloat, rampEnd: CGFloat) {
            self.blurStart = blurStart
            self.blurFull = blurFull
            self.rampStart = rampStart
            self.rampEnd = rampEnd
        }

        /// The same fade, `dy` further down — for handing it to a view whose
        /// origin sits `-dy` from the one it was measured in.
        public func offset(by dy: CGFloat) -> Geometry {
            Geometry(
                blurStart: blurStart + dy, blurFull: blurFull + dy,
                rampStart: rampStart + dy, rampEnd: rampEnd + dy
            )
        }
    }

    /// How far above the type the blur's container starts.
    ///
    /// ⚠️ 140, not the 96 it had while the blur was whole at the type's top:
    /// with the ease-in running on to the banner's foot, 96 left the name a
    /// third of the way down the curve, on sigma ~5 — a busy picture's
    /// stripes still showed through (4.18:1 in the better ink). At 140 it
    /// stands about 40% down, on sigma ~9, and the container's top is still
    /// well inside a poster's stage, the subject above it sharp.
    public static let blurLead: CGFloat = 140
    /// The page's tone arrives over this much, centred on the banner's edge.
    ///
    /// Sized by the SEAM it crosses, not by taste: the edge sits between two
    /// lines of type in both headers — white on the picture above, page ink
    /// on the page below — and each needs its own ground whole. The profile
    /// leaves ~8pt of air there (the handle's line foot to the counters'
    /// top), the place 16pt; a ramp longer than the seam lays page tone
    /// under white type or leaves page ink on the picture.
    public static let rampLength: CGFloat = 12
    /// The levels' blur, as Gaussian sigmas in on-screen points. Doubling,
    /// so each blend is between two neighbours close enough that no double
    /// image shows through the mix.
    ///
    /// ⚠️ UP TO 56pt at the banner's foot, a wash of the picture's colours
    /// rather than a softened picture: the type's ink is picked from the
    /// ground (`HeroInk.tone`), and one ink per block is only right over an
    /// even one. Measured under a place's name while it stood on the
    /// strongest level: at 13pt the ground ran from luminance 0.04 (hair) to
    /// 0.40 (a wall), 2.34:1 in the better ink; at 56pt, 0.15 to 0.20.
    public static let blurSigmas: [CGFloat] = [1.5, 3.5, 7, 14, 28, 56]

    /// The fade for type whose first line's top is `typeTop` on a banner whose
    /// edge — where the page takes over — is at `edge`: the page's tone over
    /// `rampLength`, centred on the edge, whose foot is the banner's; the
    /// blur climbing from `lead` above the type all the way to that foot.
    public static func geometry(typeTop: CGFloat, edge: CGFloat, lead: CGFloat = blurLead) -> Geometry {
        Geometry(
            blurStart: typeTop - lead, blurFull: edge + rampLength / 2,
            rampStart: edge - rampLength / 2, rampEnd: edge + rampLength / 2
        )
    }

    /// The blur's curve: at `t` of the way down its container the sigma is
    /// `t^blurCurveExponent` of the strongest.
    ///
    /// ⚠️ QUADRATIC, an ease-in (user, 30 September 2026: 0% at the
    /// container's top, 100% at its bottom, non-linear, sharp longer at the
    /// top). Linear spent its visible change in the first few points — sigma
    /// 5.6 already a tenth of the way down, read as a line where the blur
    /// starts. Quadratic keeps the upper third under sigma 6 (still reads as
    /// the picture) and thickens through the lower half. Cubic was the other
    /// candidate and was rejected: it leaves the type — a third to a half of
    /// the way down — on sigma 2–7, where a portrait's features still show
    /// through, and one ink per block needs a calm ground (`HeroInk.tone`).
    public static let blurCurveExponent: CGFloat = 2

    /// Where each level fades in: from where the wanted sigma passes the
    /// previous level's to where it reaches this one's, along
    /// `blurCurveExponent` — so the levels crowd towards the foot, where the
    /// sigma climbs fastest.
    public static func levelSpans(_ geometry: Geometry) -> [(start: CGFloat, full: CGFloat)] {
        guard let strongest = blurSigmas.last, strongest > 0 else { return [] }
        let lead = max(0, geometry.blurFull - geometry.blurStart)
        func depth(_ sigma: CGFloat) -> CGFloat {
            geometry.blurStart + lead * pow(sigma / strongest, 1 / blurCurveExponent)
        }
        var previous: CGFloat = 0
        return blurSigmas.map { sigma in
            defer { previous = sigma }
            return (depth(previous), depth(sigma))
        }
    }

    /// How many segments the ramp's ease is sampled in.
    static let rampSamples = 4

    /// The ramp's stops, as (location, alpha) pairs, for a view of `height`:
    /// clear, a smoothstep to the page's tone, then the page.
    public static func rampStops(height: CGFloat, geometry: Geometry) -> [(CGFloat, CGFloat)] {
        guard height > 0 else { return [] }
        func fraction(_ y: CGFloat) -> CGFloat { max(0, min(y / height, 1)) }
        var stops: [(CGFloat, CGFloat)] = [(0, 0)]
        for sample in 0...rampSamples {
            let t = CGFloat(sample) / CGFloat(rampSamples)
            let y = geometry.rampStart + (geometry.rampEnd - geometry.rampStart) * t
            stops.append((fraction(y), t * t * (3 - 2 * t)))
        }
        stops.append((1, 1))
        return stops
    }

    // MARK: - Baking

    /// Pixels per on-screen point a level is baked at: the faint levels at
    /// one, so their few points of blur are still a blur and not a
    /// resampling; the stronger ones at a half and a quarter, which their
    /// radius hides.
    static func bakeScale(forSigma sigma: CGFloat) -> CGFloat {
        sigma < 3 ? 1 : (sigma < 10 ? 0.5 : 0.25)
    }

    /// The picture, blurred once per level, for a picture shown `displayScale`
    /// on-screen points per image point. Nil when there is nothing to bake.
    static func bakeLevels(of image: UIImage, displayScale: CGFloat) -> [UIImage]? {
        guard displayScale > 0, image.size.width > 0, image.size.height > 0 else { return nil }
        var levels: [UIImage] = []
        // Drawn once per resolution, shared by the levels baked at it.
        var sources: [CGFloat: CGImage] = [:]
        for sigma in blurSigmas {
            let scale = bakeScale(forSigma: sigma)
            let source: CGImage
            if let drawn = sources[scale] {
                source = drawn
            } else {
                let size = CGSize(
                    width: max(1, (image.size.width * displayScale * scale).rounded()),
                    height: max(1, (image.size.height * displayScale * scale).rounded())
                )
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                format.opaque = true
                let drawn = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                    image.draw(in: CGRect(origin: .zero, size: size))
                }
                guard let cgImage = drawn.cgImage else { return nil }
                sources[scale] = cgImage
                source = cgImage
            }
            guard let blurred = blur(source, sigma: sigma * scale) else { return nil }
            levels.append(UIImage(cgImage: blurred))
        }
        return levels
    }

    /// Three box passes — a Gaussian to within a few percent — at the box
    /// width whose three-fold variance is `sigma`².
    private static func blur(_ image: CGImage, sigma: CGFloat) -> CGImage? {
        guard var format = vImage_CGImageFormat(
            bitsPerComponent: 8, bitsPerPixel: 32,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )
        ) else { return nil }
        guard var source = try? vImage_Buffer(cgImage: image, format: format) else { return nil }
        defer { source.free() }
        guard var scratch = try? vImage_Buffer(
            width: Int(source.width), height: Int(source.height), bitsPerPixel: 32
        ) else { return nil }
        defer { scratch.free() }
        var box = Int((4 * sigma * sigma + 1).squareRoot().rounded())
        if box % 2 == 0 { box += 1 }
        let side = UInt32(max(1, box))
        // ⚠️ TRUNCATED, not edge-extended: extending replicated the picture's
        // outermost column across the strongest level's reach, so a name
        // 20pt from the edge stood on the edge's tone rather than the
        // picture's (measured on 2px stripes: 3.50 worst vs 4.12 typical).
        // A truncated kernel averages what is really there.
        let flags = vImage_Flags(kvImageTruncateKernel)
        guard vImageBoxConvolve_ARGB8888(&source, &scratch, nil, 0, 0, side, side, nil, flags) == kvImageNoError,
              vImageBoxConvolve_ARGB8888(&scratch, &source, nil, 0, 0, side, side, nil, flags) == kvImageNoError,
              vImageBoxConvolve_ARGB8888(&source, &scratch, nil, 0, 0, side, side, nil, flags) == kvImageNoError
        else { return nil }
        return try? scratch.createCGImage(format: format)
    }
}

/// A banner's picture with `HeroBannerFade`'s progressive blur: an
/// aspect-filled image, and over it the baked levels, each masked to where it
/// fades in. Pin it where the picture shows; give it the fade in its own
/// coordinates whenever layout moves the type (`fade`), and move the picture
/// inside it with `pictureOutset` / `pictureShift` — never by moving the view,
/// since the blur's masks belong to the banner, not to the picture: a
/// parallax slides the picture UNDER a blur that stays with the type.
///
/// Put the page's tone over it with a `HeroBannerRampView` in the same
/// coordinates.
public final class HeroBannerPictureView: UIView {
    /// The picture. Setting the same instance again does nothing.
    public var image: UIImage? {
        get { sharp.image }
        set {
            guard newValue !== sharp.image else { return }
            sharp.image = newValue
            baked = nil; baking = nil
            for level in levels { level.picture.image = nil }
            setNeedsLayout()
        }
    }

    /// How far the picture reaches past this view's bounds — room for a
    /// parallax to slide it without uncovering an edge.
    public var pictureOutset: UIEdgeInsets = .zero {
        didSet { if pictureOutset != oldValue { setNeedsLayout() } }
    }

    /// How far down the picture is slid inside the view — the parallax. Moves
    /// the picture and its baked levels together; the masks stay put.
    public var pictureShift: CGFloat = 0 {
        didSet {
            guard pictureShift != oldValue else { return }
            let shift = CGAffineTransform(translationX: 0, y: pictureShift)
            sharp.transform = shift
            for level in levels { level.picture.transform = shift }
        }
    }

    /// The fade, in this view's coordinates. Nil shows the picture sharp.
    public var fade: HeroBannerFade.Geometry? {
        didSet { if fade != oldValue { setNeedsLayout() } }
    }

    /// Where the picture stands, slid by the parallax, in this view's space.
    public var pictureFrame: CGRect {
        bounds.inset(by: UIEdgeInsets(
            top: -pictureOutset.top, left: -pictureOutset.left,
            bottom: -pictureOutset.bottom, right: -pictureOutset.right
        )).offsetBy(dx: 0, dy: pictureShift)
    }

    private let sharp = FillImageView()
    private struct Level {
        /// Clips to the rows the level can show and carries its mask, so the
        /// offscreen pass a mask costs covers only those rows.
        let host: UIView
        let mask: CAGradientLayer
        let picture: FillImageView
    }
    private var levels: [Level] = []
    /// What the levels were baked for: the picture and its display scale.
    private var baked: (image: ObjectIdentifier, scale: CGFloat)?

    // MARK: - The ground under the type

    /// Called whenever the baked levels change — the moment a header can read
    /// the ground under its type and pick its ink (`HeroInk.tone`).
    public var onLevelsChanged: (() -> Void)?

    /// The blurred picture's pixels behind `rect` (this view's coordinates),
    /// with the picture AT REST — the parallax is not the picture's to
    /// decide an ink by. Nil until the levels are baked.
    ///
    /// Read from the level that is WHOLE at the rect's top — the least
    /// blurred ground the block stands on, since the blur keeps climbing
    /// under the type down to the banner's foot (`HeroBannerFade`): an ink
    /// that holds over it holds over the blurrier rows below. Above the
    /// faintest level's full point, the faintest level stands in. Read on
    /// demand, only the rect's pixels, so nothing is kept between bakes.
    public func groundPixels(behind rect: CGRect) -> [SIMD3<Float>]? {
        guard baked != nil, let fade else { return nil }
        let spans = HeroBannerFade.levelSpans(fade)
        let shown = levels.indices.last { $0 < spans.count && spans[$0].full <= rect.minY } ?? 0
        guard let image = levels[shown].picture.image?.cgImage,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let frame = pictureFrame.offsetBy(dx: 0, dy: -pictureShift)
        let scale = max(frame.width / CGFloat(image.width), frame.height / CGFloat(image.height))
        guard scale > 0 else { return nil }
        let origin = CGPoint(
            x: frame.midX - CGFloat(image.width) * scale / 2,
            y: frame.midY - CGFloat(image.height) * scale / 2
        )
        let area = rect.intersection(bounds)
        guard !area.isNull, area.width > 0, area.height > 0 else { return nil }
        let pixelRect = CGRect(
            x: (area.minX - origin.x) / scale, y: (area.minY - origin.y) / scale,
            width: area.width / scale, height: area.height / scale
        ).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !pixelRect.isNull, pixelRect.width >= 1, pixelRect.height >= 1,
              let crop = image.cropping(to: pixelRect) else { return nil }
        let width = crop.width, height = crop.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var pixels: [SIMD3<Float>] = []
        pixels.reserveCapacity(width * height)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            pixels.append(SIMD3(
                Float(bytes[index]) / 255, Float(bytes[index + 1]) / 255, Float(bytes[index + 2]) / 255
            ))
        }
        return pixels
    }

    override public init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
        sharp.contentMode = .scaleAspectFill
        sharp.clipsToBounds = true
        addSubview(sharp)
        levels = HeroBannerFade.blurSigmas.map { _ in
            let host = UIView()
            host.isUserInteractionEnabled = false
            host.clipsToBounds = true
            host.isHidden = true
            let mask = CAGradientLayer()
            mask.colors = [UIColor.clear.cgColor, UIColor.black.cgColor]
            host.layer.mask = mask
            let picture = FillImageView()
            picture.contentMode = .scaleAspectFill
            host.addSubview(picture)
            addSubview(host)
            return Level(host: host, mask: mask, picture: picture)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        // At rest; the parallax is a transform on top (see `pictureShift`).
        let rest = pictureFrame.offsetBy(dx: 0, dy: -pictureShift)
        place(sharp, at: rest)
        bakeIfNeeded(for: rest.size)
        let spans = fade.map(HeroBannerFade.levelSpans) ?? []
        for (index, level) in levels.enumerated() {
            guard baked != nil, index < spans.count, bounds.height > 0,
                  spans[index].start < bounds.height
            else {
                level.host.isHidden = true
                continue
            }
            let span = spans[index]
            let top = max(0, span.start.rounded(.down))
            level.host.isHidden = false
            level.host.frame = CGRect(x: 0, y: top, width: bounds.width, height: bounds.height - top)
            place(level.picture, at: rest.offsetBy(dx: 0, dy: -top))
            let height = level.host.bounds.height
            level.mask.frame = level.host.bounds
            level.mask.locations = [span.start, max(span.full, span.start + 1)].map {
                NSNumber(value: Double(max(0, min(($0 - top) / height, 1))))
            }
        }
        #if DEBUG
        layoutMaterialComparison()
        #endif
    }

    #if DEBUG
    /// `-hero-blur-material`: the public-API alternative this view rejected —
    /// one `UIVisualEffectView` blur under a gradient mask over the same
    /// climb — in place of the baked levels, for side-by-side screenshots.
    /// Never shipped: its tint is the frost `HeroBannerFade` explains.
    private static let comparesMaterial = ProcessInfo.processInfo.arguments.contains("-hero-blur-material")
    private var material: (view: UIVisualEffectView, mask: CAGradientLayer)?

    private func layoutMaterialComparison() {
        guard Self.comparesMaterial, let fade, bounds.height > 0 else { return }
        for level in levels { level.host.isHidden = true }
        let material = self.material ?? {
            let view = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
            let maskView = MaskView()
            view.mask = maskView
            addSubview(view)
            let made = (view, maskView.gradient)
            self.material = made
            return made
        }()
        let top = max(0, fade.blurStart.rounded(.down))
        material.view.frame = CGRect(x: 0, y: top, width: bounds.width, height: bounds.height - top)
        material.view.mask?.frame = material.view.bounds
        let height = material.view.bounds.height
        material.mask.colors = [UIColor.clear.cgColor, UIColor.black.cgColor]
        material.mask.locations = [fade.blurStart, fade.blurFull].map {
            NSNumber(value: Double(max(0, min(($0 - top) / height, 1))))
        }
    }

    private final class MaskView: UIView {
        override class var layerClass: AnyClass { CAGradientLayer.self }
        var gradient: CAGradientLayer { layer as! CAGradientLayer }
    }
    #endif

    /// Frames a picture through bounds and centre, so its parallax transform
    /// can stay on while layout moves it.
    private func place(_ view: UIView, at frame: CGRect) {
        view.bounds = CGRect(origin: .zero, size: frame.size)
        view.center = CGPoint(x: frame.midX, y: frame.midY)
        view.transform = CGAffineTransform(translationX: 0, y: pictureShift)
    }

    /// How far the picture's display scale may drift from the one its levels
    /// were baked at before they are baked again. The levels are aspect-filled
    /// like the picture, so a drift only scales their blur with it — a pull
    /// to stretch the banner grows the scale continuously, and re-baking at
    /// every tenth of it cost a bake per few frames of the gesture.
    static let rebakeTolerance: CGFloat = 0.35

    /// The bake in flight, if any — so a layout pass during it does not
    /// start the same one again, and a stale one lands nowhere.
    private var baking: (image: ObjectIdentifier, scale: CGFloat)?

    /// Bakes the levels once per picture and display scale (within
    /// `rebakeTolerance`).
    ///
    /// ⚠️ OFF THE MAIN THREAD ON SCREEN. Measured on the iPhone 18 Pro
    /// simulator: a real banner (a camera photograph, decoded on first draw)
    /// cost 30ms — two frames — when baked in the layout pass of a profile
    /// arriving. On screen the bake runs on a background queue and the levels
    /// dissolve in when it lands; the picture shows sharp for those few
    /// frames, under the ramp. Off screen (a header being built, a test)
    /// nobody sees a frame, and it bakes in place.
    private func bakeIfNeeded(for size: CGSize) {
        guard let image = sharp.image, image.size.width > 0, image.size.height > 0,
              size.width > 0, size.height > 0
        else { return }
        let scale = max(size.width / image.size.width, size.height / image.size.height)
        let identity = ObjectIdentifier(image)
        func matches(_ key: (image: ObjectIdentifier, scale: CGFloat)?) -> Bool {
            guard let key else { return false }
            return key.image == identity && abs(key.scale - scale) <= key.scale * Self.rebakeTolerance
        }
        guard !matches(baked), !matches(baking) else { return }
        let key = (identity, scale)
        guard window != nil else {
            let began = CACurrentMediaTime()
            guard let images = HeroBannerFade.bakeLevels(of: image, displayScale: scale) else { return }
            adopt(images, for: key, size: size, milliseconds: (CACurrentMediaTime() - began) * 1000)
            return
        }
        baking = key
        DispatchQueue.global(qos: .userInitiated).async {
            let began = CACurrentMediaTime()
            let images = HeroBannerFade.bakeLevels(of: image, displayScale: scale)
            let milliseconds = (CACurrentMediaTime() - began) * 1000
            DispatchQueue.main.async { [weak self] in
                guard let self, let baking = self.baking, baking.image == key.0, baking.scale == key.1
                else { return }
                self.baking = nil
                guard let images, self.sharp.image.map(ObjectIdentifier.init) == key.0 else { return }
                UIView.transition(
                    with: self, duration: 0.2, options: [.transitionCrossDissolve, .allowUserInteraction]
                ) {
                    self.adopt(images, for: key, size: size, milliseconds: milliseconds)
                    self.layoutIfNeeded()
                }
            }
        }
    }

    private func adopt(
        _ images: [UIImage], for key: (image: ObjectIdentifier, scale: CGFloat), size: CGSize,
        milliseconds: Double
    ) {
        #if DEBUG
        debugLastBakeMilliseconds = milliseconds
        debugLastBakeBytes = images.reduce(0) { total, level in
            total + (level.cgImage.map { $0.bytesPerRow * $0.height } ?? 0)
        }
        if ProcessInfo.processInfo.arguments.contains("-hero-blur-trace") {
            print(String(
                format: "HERO-BLUR baked %d levels for %.0fx%.0fpt in %.1fms (%@), %.0f KB",
                images.count, size.width, size.height, milliseconds,
                window == nil ? "in place" : "background", Double(debugLastBakeBytes) / 1024
            ))
        }
        #endif
        baked = key
        for (level, image) in zip(levels, images) { level.picture.image = image }
        setNeedsLayout()
        onLevelsChanged?()
    }

    #if DEBUG
    /// The last bake's cost, for the trace and the tests.
    public private(set) var debugLastBakeMilliseconds: Double = 0
    public private(set) var debugLastBakeBytes = 0
    /// The levels showing, and each one's mask stops in this view's space.
    public var debugVisibleLevels: [(start: CGFloat, full: CGFloat)] {
        levels.filter { !$0.host.isHidden && $0.picture.image != nil }.map { level in
            let locations = (level.mask.locations ?? []).map { CGFloat($0.doubleValue) }
            let height = level.host.bounds.height
            return (level.host.frame.minY + (locations.first ?? 0) * height,
                    level.host.frame.minY + (locations.last ?? 0) * height)
        }
    }
    #endif
}

/// The page's tone over the foot of a `HeroBannerPictureView` — the short
/// ramp of `HeroBannerFade`. Pin it over the picture in the same
/// coordinates and hand it the same `fade`.
public final class HeroBannerRampView: UIView {
    override public class var layerClass: AnyClass { CAGradientLayer.self }

    /// The fade, in this view's coordinates. Nil draws nothing.
    public var fade: HeroBannerFade.Geometry? {
        didSet { if fade != oldValue { setNeedsLayout() } }
    }

    /// The tone the ramp lands on — the page the header sits on.
    public var tone: UIColor = Surface.page {
        didSet { setNeedsLayout() }
    }

    override public init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        // A CGColor does not follow the appearance; re-resolve on a flip.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: HeroBannerRampView, _) in
            self.setNeedsLayout()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var gradient: CAGradientLayer? { layer as? CAGradientLayer }

    override public func layoutSubviews() {
        super.layoutSubviews()
        guard let gradient else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let fade, bounds.height > 0 else {
            gradient.colors = []
            return
        }
        let stops = HeroBannerFade.rampStops(height: bounds.height, geometry: fade)
        let tone = tone.resolvedColor(with: traitCollection)
        gradient.locations = stops.map { NSNumber(value: Double($0.0)) }
        gradient.colors = stops.map { tone.withAlphaComponent($0.1).cgColor }
    }

    #if DEBUG
    public var debugLocations: [CGFloat] { (gradient?.locations ?? []).map { CGFloat($0.doubleValue) } }
    public var debugAlphas: [CGFloat] { (gradient?.colors as? [CGColor] ?? []).map { $0.alpha } }
    #endif
}

/// An image view sized by its constraints or frame only: a loaded bitmap's
/// intrinsic size must not vote (see the profile header's no-intrinsic-image
/// rule).
private final class FillImageView: UIImageView {
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }
}
