import UIKit

/// The ink of type that stands ON a picture-led header's photograph — a
/// profile's poster name and handle, a place's name — and the scrim that
/// makes it legible there.
///
/// ⚠️ **TYPE ON A PHOTOGRAPH WEARS THE PICTURE'S INK, NOT THE PAGE'S.** Both
/// headers used to keep `.label` over the raw picture, dressed with a
/// page-coloured halo or a page-coloured plate: black type over the dark
/// clothes, hair and shadow nearly every portrait carries at the height of a
/// name read faint in light mode, and white type over a bright table or sky
/// in dark mode. No page colour survives an arbitrary photograph. What every
/// media app does does: white type over a black scrim that darkens the foot
/// of the picture, the same in both appearances.
///
/// The scrim (`HeroInkScrimView`) eases in from clear well above the type —
/// so the subject is left alone and there is no edge to see — reaches
/// `scrimPeak` just above it, and holds under it. What it does below depends
/// on the PAGE it runs into:
/// - a dark page (dark mode): it holds to the foot. The page's run-out is the
///   same tone, so the two join without a seam;
/// - a light page: it gives way by `Band.release` — the next row of page-ink
///   type — as the page's tone arrives. Held to the foot there, it greys the
///   counters and whatever follows; given way, the picture brightens
///   monotonically from the type into the page, with no dark band left at
///   the header's foot, where a glass control could resolve over mid-grey.
///
/// `scrimPeak` is set by the worst picture there is — pure white — against
/// `secondary`, the fainter of the two inks: 0.62 black over white leaves
/// `secondary` 5.0:1 and `primary` 6.2:1, over the 4.5:1 WCAG asks of body
/// text. Measured on rendered pixels, not assumed: see `debugContrast`.
public enum HeroInk {
    /// The ink of the headline on a picture: a name.
    public static let primary = UIColor.white
    /// The ink of a second line on a picture — a handle. Its step below the
    /// headline is a touch of transparency and no more: 0.85 is what still
    /// clears 4.5:1 over a pure white picture.
    public static let secondary = UIColor.white.withAlphaComponent(0.85)

    public static let scrimPeak: CGFloat = 0.62
    /// How far above the type the scrim starts climbing — too gentle a climb
    /// to read as an edge.
    public static let scrimLead: CGFloat = 96
    /// The scrim is at its peak this far outside the type on either side.
    public static let scrimPad: CGFloat = 8
    /// How many segments the climb is sampled in — see `scrimStops`.
    public static let scrimClimbSamples = 6

    /// Where the type stands, in the scrim's own points from its top: the
    /// first line's top, the last line's foot, and where the page's run-out
    /// takes over (the top of the next row, which wears page ink).
    public struct Band: Equatable, Sendable {
        public var top: CGFloat
        public var bottom: CGFloat
        public var release: CGFloat

        public init(top: CGFloat, bottom: CGFloat, release: CGFloat) {
            self.top = top
            self.bottom = bottom
            self.release = release
        }
    }

    /// The scrim's stops, as (location, alpha) pairs, for a scrim of
    /// `height`. The climb is a smoothstep, so it leaves clear and arrives at
    /// the peak without a crease at either end.
    public static func scrimStops(height: CGFloat, band: Band, holdsToFoot: Bool) -> [(CGFloat, CGFloat)] {
        guard height > 0 else { return [] }
        func fraction(_ y: CGFloat) -> CGFloat { max(0, min(y / height, 1)) }
        let peakStart = fraction(band.top - scrimPad)
        let climbStart = fraction(band.top - scrimPad - scrimLead)
        let peakEnd = max(peakStart, fraction(band.bottom + scrimPad))
        var stops: [(CGFloat, CGFloat)] = []
        for sample in 0...scrimClimbSamples {
            let t = CGFloat(sample) / CGFloat(scrimClimbSamples)
            let eased = t * t * (3 - 2 * t)
            stops.append((climbStart + (peakStart - climbStart) * t, scrimPeak * eased))
        }
        stops.append((peakEnd, scrimPeak))
        if holdsToFoot {
            stops.append((1, scrimPeak))
        } else {
            stops.append((max(peakEnd, fraction(band.release)), 0))
            stops.append((1, 0))
        }
        return stops
    }

    /// Whether the page under `traits` is dark — which decides where the
    /// scrim ends.
    public static func pageIsDark(_ traits: UITraitCollection) -> Bool {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
        Surface.page.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: nil)
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue < 0.5
    }

    /// `page` at 0, `picture` at 1, blended in between — for type whose
    /// picture fades away under it on a scroll (white kept over a light page
    /// would vanish). Resolved per appearance, so a mid-fade colour still
    /// follows a style flip; the ends are the colours themselves.
    public static func blend(page: UIColor, picture: UIColor, onPicture t: CGFloat) -> UIColor {
        if t <= 0 { return page }
        if t >= 1 { return picture }
        return UIColor { traits in
            var from = (r: CGFloat(0), g: CGFloat(0), b: CGFloat(0), a: CGFloat(0))
            var to = from
            page.resolvedColor(with: traits).getRed(&from.r, green: &from.g, blue: &from.b, alpha: &from.a)
            picture.resolvedColor(with: traits).getRed(&to.r, green: &to.g, blue: &to.b, alpha: &to.a)
            return UIColor(
                red: from.r + (to.r - from.r) * t,
                green: from.g + (to.g - from.g) * t,
                blue: from.b + (to.b - from.b) * t,
                alpha: from.a + (to.a - from.a) * t
            )
        }
    }

    /// A soft black shadow under white type: over the scrim it adds little to
    /// the numbers, but it holds a glyph's edge where a busy picture puts a
    /// highlight right behind it. Scaled by how much of the ink is the
    /// picture's; none at all on the page. Not trait-dependent, so it never
    /// needs re-resolving.
    @MainActor public static func applyShadow(to label: UILabel, onPicture t: CGFloat) {
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOffset = CGSize(width: 0, height: 1)
        label.layer.shadowRadius = 3
        label.layer.shadowOpacity = Float(0.3 * max(0, min(t, 1)))
    }
}

/// The scrim under type that stands on a picture — see `HeroInk`. Pin it
/// over the picture and under any page-toned run-out, and hand it the
/// type's `band` in its own coordinates whenever layout moves the type.
public final class HeroInkScrimView: UIView {
    override public class var layerClass: AnyClass { CAGradientLayer.self }

    /// Nil draws nothing.
    public var band: HeroInk.Band? {
        didSet { if band != oldValue { setNeedsLayout() } }
    }

    override public init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        // Where the scrim ends depends on the page's tone.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: HeroInkScrimView, _) in
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
        guard let band, band.bottom > band.top, bounds.height > 0 else {
            gradient.colors = []
            return
        }
        let stops = HeroInk.scrimStops(
            height: bounds.height, band: band, holdsToFoot: HeroInk.pageIsDark(traitCollection)
        )
        gradient.locations = stops.map { NSNumber(value: Double($0.0)) }
        gradient.colors = stops.map { UIColor.black.withAlphaComponent($0.1).cgColor }
    }

    #if DEBUG
    public var debugLocations: [CGFloat] { (gradient?.locations ?? []).map { CGFloat($0.doubleValue) } }
    public var debugAlphas: [CGFloat] { (gradient?.colors as? [CGColor] ?? []).map { $0.alpha } }
    #endif
}

#if DEBUG
/// WCAG contrast of a label against what is actually drawn behind it.
public struct HeroInkContrast: CustomStringConvertible, Sendable {
    /// The worst pixel — the number a guideline asks about.
    public var min: CGFloat
    /// The typical pixel.
    public var median: CGFloat
    public var description: String { String(format: "min %.2f median %.2f", min, median) }
}

extension HeroInk {
    /// Measures each of `labels` against the pixels `container` renders
    /// behind it: the container is drawn over `background` with the labels
    /// hidden, and every pixel under a label's TEXT (not its full frame) is
    /// compared with the label's ink composited over that pixel. Used by the
    /// headers' tests and their `-…-ink-audit` launch arguments.
    @MainActor public static func debugContrast(
        of labels: [UILabel], in container: UIView, over background: UIColor
    ) -> [HeroInkContrast]? {
        container.layoutIfNeeded()
        let size = container.bounds.size
        guard size.width > 0, size.height > 0 else { return nil }
        let alphas = labels.map { $0.alpha }
        labels.forEach { $0.alpha = 0 }
        defer { zip(labels, alphas).forEach { $0.alpha = $1 } }

        let width = Int(size.width.rounded(.up))
        let height = Int(size.height.rounded(.up))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        // UIKit's top-left origin, so a pixel's row is its y in points.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        let traits = container.traitCollection
        context.setFillColor(background.resolvedColor(with: traits).cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        container.layer.render(in: context)
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }

        func luminance(_ rgb: [CGFloat]) -> CGFloat {
            let linear = rgb.map { channel -> CGFloat in
                let c = Swift.max(0, Swift.min(channel, 1))
                return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
        }

        return labels.map { label in
            let text = label.textRect(forBounds: label.bounds, limitedToNumberOfLines: label.numberOfLines)
            let rect = label.convert(text, to: container).integral
                .intersection(CGRect(x: 0, y: 0, width: width, height: height))
            var ink = (r: CGFloat(0), g: CGFloat(0), b: CGFloat(0), a: CGFloat(0))
            label.textColor.resolvedColor(with: traits).getRed(&ink.r, green: &ink.g, blue: &ink.b, alpha: &ink.a)
            var ratios: [CGFloat] = []
            if !rect.isNull {
                for y in Int(rect.minY)..<Int(rect.maxY) {
                    for x in Int(rect.minX)..<Int(rect.maxX) {
                        let offset = y * width * 4 + x * 4
                        let back = (0..<3).map { CGFloat(data[offset + $0]) / 255 }
                        let front = zip([ink.r, ink.g, ink.b], back).map { $0 * ink.a + $1 * (1 - ink.a) }
                        let a = luminance(front)
                        let b = luminance(back)
                        ratios.append((Swift.max(a, b) + 0.05) / (Swift.min(a, b) + 0.05))
                    }
                }
            }
            ratios.sort()
            guard let worst = ratios.first else { return HeroInkContrast(min: 0, median: 0) }
            return HeroInkContrast(min: worst, median: ratios[ratios.count / 2])
        }
    }
}
#endif
