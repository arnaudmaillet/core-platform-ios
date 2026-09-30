import UIKit

/// The ink of type that stands ON a picture-led header's photograph — a
/// profile's name and handle on its band or poster (and, on a poster, its
/// counters, bio and link), a place's name and counters.
///
/// ⚠️ **TYPE ON A PHOTOGRAPH WEARS THE PICTURE'S INK, NOT THE PAGE'S.** Both
/// headers used to keep `.label` over the raw picture: black type over the
/// dark clothes, hair and shadow nearly every portrait carries at the height
/// of a name read faint in light mode, and white type over a bright table or
/// sky in dark mode. No page colour survives an arbitrary photograph.
///
/// ⚠️ **THE PICTURE PICKS THE INK — white on a dark picture, black on a
/// light one — the same in both appearances.** There is no scrim under the
/// type: #327's black gradient read as a veil and went (30 September 2026),
/// and white type alone over a light picture measured 2.34:1 (a place's
/// banner). What stands under the type is `HeroBannerFade`'s progressive
/// blur, which evens the ground out — which is what makes ONE ink per
/// block right: `tone(forGround:current:)` reads the blurred picture behind
/// each block and keeps whichever ink's worst pixel clears more. Over an
/// even ground the better of black and white never falls below 4.58:1 (the
/// crossover, a ground of luminance 0.18).
///
/// ⚠️ OVER AN UNEVEN GROUND NO INK HOLDS. Where the blur leaves both light
/// and dark behind one block — a place's name over a light face and dark
/// hair, measured luminance 0.03 to 0.46 — the better ink's worst pixel is
/// ~2.3:1. That is the one thing a picked ink cannot fix without a layer
/// that changes the picture's tone, which the design refused (30 September
/// 2026); the audits print it rather than hide it.
public enum HeroInk {
    /// Which ink a block of type on a picture wears.
    public enum Tone: Equatable, Sendable {
        /// White ink, for a dark picture.
        case light
        /// Black ink, for a light picture.
        case dark

        /// The headline's ink: a name, a counter's value.
        public var primary: UIColor { self == .light ? .white : .black }
        /// A second line's — a handle, a caption: the SAME opaque ink; its
        /// step below the headline is the type's (size, weight), not the
        /// colour's.
        ///
        /// ⚠️ It was the ink at 0.85. Over an even ground, the better of
        /// black and white at 0.85 bottoms out at 3.96:1 (a ground around
        /// sRGB 0.45); only opaque inks keep every ground at or above 4.58:1.
        public var secondary: UIColor { primary }
    }

    /// The ink until the picture has been read: most banners are
    /// photographs darker at the foot than a white page.
    public static let defaultTone = Tone.light

    /// The contrast WCAG asks of body text.
    public static let legible: CGFloat = 4.5
    /// How much better the other ink must do before a block that is not
    /// legible in its own switches — so a mid picture, whose two inks score
    /// alike, does not flip each time the banner is re-read.
    public static let switchMargin: CGFloat = 0.25

    /// The ink for a block standing on `ground` — the blurred picture's
    /// pixels behind it, sRGB 0…1 — given the ink it wears now.
    ///
    /// Scored by the WORST pixel of each tone's weaker ink (`secondary`). A
    /// block that is legible in its current ink keeps it; one that is not
    /// takes the other only when that does clearly better.
    public static func tone(forGround ground: [SIMD3<Float>], current: Tone?) -> Tone {
        guard !ground.isEmpty else { return current ?? defaultTone }
        func worst(_ tone: Tone) -> CGFloat {
            var ink = (r: CGFloat(0), g: CGFloat(0), b: CGFloat(0), a: CGFloat(0))
            tone.secondary.getRed(&ink.r, green: &ink.g, blue: &ink.b, alpha: &ink.a)
            var lowest = CGFloat.greatestFiniteMagnitude
            for pixel in ground {
                let back = [CGFloat(pixel.x), CGFloat(pixel.y), CGFloat(pixel.z)]
                let front = zip([ink.r, ink.g, ink.b], back).map { $0 * ink.a + $1 * (1 - ink.a) }
                lowest = min(lowest, contrast(luminance(front), luminance(back)))
            }
            return lowest
        }
        let light = worst(.light)
        let dark = worst(.dark)
        let better: Tone = light >= dark ? .light : .dark
        guard let current else { return better }
        let mine = current == .light ? light : dark
        let theirs = current == .light ? dark : light
        if mine >= legible { return current }
        return theirs > mine + switchMargin ? (current == .light ? .dark : .light) : current
    }

    #if DEBUG
    /// `-hero-blur-trace`: the ground's luminance spread and each ink's worst
    /// contrast over it, for a block called `name`.
    public static func debugTraceGround(_ ground: [SIMD3<Float>], name: String, picked: Tone) {
        guard ProcessInfo.processInfo.arguments.contains("-hero-blur-trace"), !ground.isEmpty else { return }
        let lums = ground.map { luminance([CGFloat($0.x), CGFloat($0.y), CGFloat($0.z)]) }.sorted()
        func at(_ p: Double) -> CGFloat { lums[min(lums.count - 1, Int(Double(lums.count - 1) * p))] }
        let white = contrast(1, lums.last!), black = contrast(0, lums.first!)
        print(String(
            format: "HERO-INK %@ ground L p0 %.3f p10 %.3f p50 %.3f p90 %.3f p100 %.3f | white worst %.2f black worst %.2f -> %@",
            name, at(0), at(0.1), at(0.5), at(0.9), at(1), white, black, picked == .light ? "white" : "black"
        ))
    }
    #endif

    /// WCAG relative luminance of an sRGB colour.
    public static func luminance(_ rgb: [CGFloat]) -> CGFloat {
        let linear = rgb.map { channel -> CGFloat in
            let c = max(0, min(channel, 1))
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }

    /// WCAG contrast ratio of two relative luminances.
    public static func contrast(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
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

    /// A soft shadow of the OPPOSITE tone under the type: black under white,
    /// a lighter touch of white under black (a dark halo reads as a glow, a
    /// light one as an engraving, so it is kept fainter). It holds a glyph's
    /// edge where the picture puts its own tone right behind it. Scaled by
    /// how much of the ink is the picture's; none at all on the page. (The
    /// contrast instrument hides the labels, shadows and all, so it never
    /// counts in the numbers.)
    @MainActor public static func applyShadow(to label: UILabel, tone: Tone, onPicture t: CGFloat) {
        label.layer.shadowColor = (tone == .light ? UIColor.black : UIColor.white).cgColor
        label.layer.shadowOffset = CGSize(width: 0, height: tone == .light ? 1 : 0.5)
        label.layer.shadowRadius = 3
        let strength: CGFloat = tone == .light ? 0.3 : 0.2
        label.layer.shadowOpacity = Float(strength * max(0, min(t, 1)))
    }
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
