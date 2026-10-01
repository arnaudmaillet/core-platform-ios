import Accelerate
import UIKit

/// How a picture-led header's banner runs out into the page — a profile's
/// band or poster, a place's banner: over one container, from just above the
/// identity to the banner's foot, the picture FADES into the page's tone and
/// grows PROGRESSIVELY BLURRED, both on steep ease-ins — next to nothing at
/// the container's top, all of it at the foot.
///
/// ```
///   ┌──────────────────────────┐
///   │      ~~~ picture ~~~     │  sharp, opaque
///   │                          │ ── container top: blur 0, fade 0
///   │ (◯)  Name                │  both barely begin under the type…
///   │      @handle  ~≈~≈~≈~≈~  │  …and climb steeper and steeper
///   │▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒│  (ease-in), the page arriving
///   └──────────────────────────┘ ── foot: blur 100%, the page's tone whole
///        35   12   3.5K           page ink on the page
/// ```
///
/// ⚠️ **THE FADE IS UNDER THE BLUR, AND BOTH ARE NEEDED.** #331 replaced the
/// long opacity ramp with the blur and kept only a 12pt seam of page tone:
/// the blur took the detail out of the picture's foot but not its colour,
/// so the line where the picture met the page stayed visible THROUGH the
/// blur (user, 30 September 2026: "the opacity effect below and the blur on
/// top"). The page's tone climbs the picture again over the whole container
/// — it is what dissolves the edge — and the blur sits over it. Drawn as a
/// page-toned ramp OVER the baked levels (`HeroBannerRampView`), which is the
/// same picture: a blur is linear, so blurring the picture after fading it
/// into a flat tone is the faded blur, as long as the fade changes slowly
/// against the blur's radius — which a ramp the container's height does.
///
/// ⚠️ **EASED IN, NOT THE HALO.** The long ramp #331 removed climbed the
/// photograph early — a white wash over its lower half on a light page, the
/// picture fogged, lit from below. This one is `rampCurveExponent` steep:
/// under the name the page is a few percent, and it is the container's last
/// third that turns into the page — where the blur has already taken the
/// picture's detail, so what dissolves is a wash of its colours, not a
/// photograph. Where the type stands on the picture from the container's
/// very top — a poster's name, a place's — the page's tone is SHOULDERED
/// instead (`shoulderedGeometry`): half of it already under the type,
/// eased in just above, the blur untouched.
///
/// ⚠️ **THE BLUR IS BAKED FROM THE PICTURE, NOT A MATERIAL.** A
/// `UIVisualEffectView` under a gradient mask was the obvious public route,
/// and it is a frost: every `UIBlurEffect` style carries a tint, white-ish on
/// a light page. These levels are the picture itself, blurred once (vImage,
/// 7–40ms on a background queue) when it lands or when its displayed size
/// changes — so they keep the picture's own colours and render in
/// `layer.render(in:)`, where the contrast instrument
/// (`HeroInk.debugContrast`) can see them. A VIDEO banner would need a live
/// blur instead; there is none today.
///
/// The progressive radius is approximated by stacking levels of increasing
/// sigma, each fading in over the stretch where the wanted sigma climbs from
/// the previous level's to its own — at any height at most two neighbouring
/// levels blend, which is what keeps the climb free of visible steps.
///
/// ⚠️ **THE LEVELS ARE BLENDED INTO ONE PICTURE, NOT STACKED UNDER MASKS.**
/// #331 drew them as six full-width layers, each under a gradient MASK, and
/// a mask is an offscreen render pass of its own — every frame the masked
/// layer's content moves, and the parallax moves it on every frame of a
/// scroll. Six passes a frame, on top of the type's shadows: on a device the
/// frame rate fell apart while scrolling either header (user, 1 October
/// 2026; the simulator draws on the Mac's GPU and could not show it —
/// `HeroScrollFrameProbe` counts the passes instead). Since at any height
/// only two neighbouring levels mix, the same picture is a ROW-BY-ROW blend
/// (`HeroBannerBlurRows`): each row of the run-out takes its two levels at
/// the row's weights, the picture's rows read where the parallax has slid
/// them. Recomposed on the CPU when the picture slides (a few hundred rows
/// of vImage blends), it reaches the render server as one plain image — no
/// mask, no offscreen pass. Metal would draw the same blend on the GPU, but
/// a Metal layer is invisible to `layer.render(in:)` — the ink audit and its
/// tests would read the sharp picture — and would have to present in step
/// with the scroll's own transaction.
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
        /// Where the page's tone has already reached `shoulderAlpha`, eased
        /// in from `rampStart` — the type's ground — before climbing on to
        /// the foot. Nil: one cubic from `rampStart` to `rampEnd`.
        public var rampShoulder: CGFloat?

        public init(
            blurStart: CGFloat, blurFull: CGFloat, rampStart: CGFloat, rampEnd: CGFloat,
            rampShoulder: CGFloat? = nil
        ) {
            self.blurStart = blurStart
            self.blurFull = blurFull
            self.rampStart = rampStart
            self.rampEnd = rampEnd
            self.rampShoulder = rampShoulder
        }

        /// The same fade, `dy` further down — for handing it to a view whose
        /// origin sits `-dy` from the one it was measured in.
        public func offset(by dy: CGFloat) -> Geometry {
            Geometry(
                blurStart: blurStart + dy, blurFull: blurFull + dy,
                rampStart: rampStart + dy, rampEnd: rampEnd + dy,
                rampShoulder: rampShoulder.map { $0 + dy }
            )
        }
    }

    /// How far above the identity's top — a profile's avatar, a place's
    /// name — the container starts.
    ///
    /// ⚠️ A FEW POINTS, not the 140 above the name it was: the user wants
    /// the blur "almost nil at the top of the container, so just above the
    /// avatar" (30 September 2026). 140 started it inside a poster's stage,
    /// and with #331's quadratic curve the name already stood on sigma ~9 —
    /// "far too strong".
    public static let blurLead: CGFloat = 8

    /// The run-out for an identity whose top is `identityTop` on a banner
    /// whose foot is `foot`: the blur and the page's tone both climbing from
    /// `blurLead` above it all the way down.
    public static func geometry(identityTop: CGFloat, foot: CGFloat) -> Geometry {
        let top = identityTop - blurLead
        return Geometry(blurStart: top, blurFull: foot, rampStart: top, rampEnd: foot)
    }

    /// The levels' blur, as Gaussian sigmas in on-screen points. Doubling,
    /// so each blend is between two neighbours close enough that no double
    /// image shows through the mix.
    ///
    /// ⚠️ UP TO 56pt at the banner's foot, a wash of the picture's colours
    /// rather than a softened picture — the page's tone arrives over it
    /// there, and a wash dissolves into a flat tone without a seam.
    public static let blurSigmas: [CGFloat] = [1.5, 3.5, 7, 14, 28, 56]

    /// The blur's curve: at `t` of the way down its container the sigma is
    /// `t^blurCurveExponent` of the strongest.
    ///
    /// ⚠️ CUBIC (user, 30 September 2026: "almost nil at the top of the
    /// container… increasing progressively toward the bottom, non-linearly —
    /// the further down, the more the rate accentuates, up to 100%"). The
    /// quadratic #331 shipped was "far too strong": over a container that
    /// began 140pt above the name it put sigma ~9 under the type. Cubic keeps
    /// the first half of the container under sigma 7 (an eighth of the
    /// strongest) and spends the rest in its lower half.
    public static let blurCurveExponent: CGFloat = 3

    /// The page tone's curve: at `t` of the way down its ramp the tone is
    /// `t^rampCurveExponent` opaque.
    ///
    /// ⚠️ CUBIC TOO, so the page never gets under type before the blur has
    /// calmed the picture it is fading: a few percent under a profile's
    /// name, an eighth half way down, whole at the foot. Squared or less
    /// climbed the photograph as the white wash the ramp was taken out for.
    public static let rampCurveExponent: CGFloat = 3

    /// How much of the page's tone already stands under the type on a
    /// shouldered ramp (`shoulderedGeometry`).
    ///
    /// ⚠️ THE USER'S CALL AFTER #335's AUDIT (30 September 2026): "start the
    /// OPACITY effect a bit earlier, without touching the blur". With the
    /// blur almost nil under the name, a poster's name stood on the sharp
    /// picture — dark hair beside a white shirt — at 1.5:1 in either ink.
    /// A flat ink needs the ground's spread closed, and only the page's tone
    /// closes it without blurring: under ~half of it the darkest hair and the
    /// brightest shirt both land on one side of the inks' crossover.
    /// Measured (`-profile-ink-audit` / `-place-ink-audit`, worst pixel,
    /// iPhone 18 Pro): at 0.55 every poster and place line clears AA in
    /// both appearances, the tightest a poster's name in the dark (5.69). At
    /// 0.5 the mock photographs cleared too (4.84), but a white picture under
    /// the dark page sat on the inks' crossover (a poster caption at 4.49 in
    /// the unit suite); at 0.4 the name fell to 3.52. Past half, the ground
    /// is always on the page's side of the crossover: a poster and a place
    /// wear the page's ink whatever the picture.
    public static let shoulderAlpha: CGFloat = 0.55
    /// How far above the shoulder the page's tone starts climbing to it —
    /// the stage above stays the picture. It does not move the contrast (48
    /// measured the same); 72 only makes the veil's top edge softer.
    public static let shoulderRise: CGFloat = 72

    /// The run-out for type that stands on the picture right from the
    /// container's top — a poster's name, a place's name: the blur as in
    /// `geometry(identityTop:foot:)`, and the page's tone eased in over
    /// `shoulderRise` to `shoulderAlpha` by the container's top, then on to
    /// whole at the foot.
    public static func shoulderedGeometry(identityTop: CGFloat, foot: CGFloat) -> Geometry {
        var geometry = geometry(identityTop: identityTop, foot: foot)
        geometry.rampShoulder = geometry.blurStart
        geometry.rampStart = geometry.blurStart - shoulderRise
        return geometry
    }

    /// The page tone's opacity at `y`, in the fade's coordinates.
    ///
    /// With a shoulder: a smoothstep from clear to `shoulderAlpha` over the
    /// rise, then the cubic from there to whole — both flat at the shoulder,
    /// so the two halves meet without a crease.
    public static func rampAlpha(at y: CGFloat, geometry: Geometry) -> CGFloat {
        func progress(_ y: CGFloat, from start: CGFloat, to end: CGFloat) -> CGFloat? {
            let length = end - start
            guard length > 0 else { return nil }
            return max(0, min((y - start) / length, 1))
        }
        if let shoulder = geometry.rampShoulder,
           shoulder > geometry.rampStart, shoulder < geometry.rampEnd {
            if y <= shoulder {
                let t = progress(y, from: geometry.rampStart, to: shoulder) ?? 1
                return shoulderAlpha * t * t * (3 - 2 * t)
            }
            let t = progress(y, from: shoulder, to: geometry.rampEnd) ?? 1
            return shoulderAlpha + (1 - shoulderAlpha) * pow(t, rampCurveExponent)
        }
        guard let t = progress(y, from: geometry.rampStart, to: geometry.rampEnd) else {
            return y >= geometry.rampEnd ? 1 : 0
        }
        return pow(t, rampCurveExponent)
    }
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

    /// How many segments the ramp's curve is sampled in — a gradient's
    /// stops are joined by straight lines, and the cubic needs enough of
    /// them not to show a kink.
    static let rampSamples = 10

    /// The ramp's stops, as (location, alpha) pairs, for a view of `height`:
    /// clear, the curve to the page's tone (`rampAlpha`, sampled — each
    /// half of a shouldered one on its own), then the page.
    public static func rampStops(height: CGFloat, geometry: Geometry) -> [(CGFloat, CGFloat)] {
        guard height > 0 else { return [] }
        func fraction(_ y: CGFloat) -> CGFloat { max(0, min(y / height, 1)) }
        var spans: [(CGFloat, CGFloat)] = [(geometry.rampStart, geometry.rampEnd)]
        if let shoulder = geometry.rampShoulder,
           shoulder > geometry.rampStart, shoulder < geometry.rampEnd {
            spans = [(geometry.rampStart, shoulder), (shoulder, geometry.rampEnd)]
        }
        var stops: [(CGFloat, CGFloat)] = [(0, 0)]
        for (index, span) in spans.enumerated() {
            for sample in (index == 0 ? 0 : 1)...rampSamples {
                let y = span.0 + (span.1 - span.0) * CGFloat(sample) / CGFloat(rampSamples)
                stops.append((fraction(y), rampAlpha(at: y, geometry: geometry)))
            }
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

    /// What one bake yields: the levels as baked (the ground the type's ink
    /// is read from, `groundPixels`) and the same levels at one pixel per
    /// point, ready to be blended row by row (`HeroBannerBlurRows`).
    struct Bake: Sendable {
        var levels: [UIImage]
        var rows: HeroBannerBlurRows
    }

    /// `bakeLevels`, then the levels brought to one resolution.
    static func bake(of image: UIImage, displayScale: CGFloat) -> Bake? {
        guard let levels = bakeLevels(of: image, displayScale: displayScale),
              let rows = HeroBannerBlurRows(levels: levels)
        else { return nil }
        return Bake(levels: levels, rows: rows)
    }

    /// Every bitmap here: 8-bit BGRA, premultiplied, sRGB — Core
    /// Animation's own layout, so an image made in it is handed to the
    /// render server without a conversion.
    static var pixelFormat: vImage_CGImageFormat? {
        vImage_CGImageFormat(
            bitsPerComponent: 8, bitsPerPixel: 32,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )
        )
    }

    /// Three box passes — a Gaussian to within a few percent — at the box
    /// width whose three-fold variance is `sigma`².
    private static func blur(_ image: CGImage, sigma: CGFloat) -> CGImage? {
        guard let format = pixelFormat else { return nil }
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

/// `HeroBannerFade`'s levels at one pixel per point of the picture as baked
/// — the faintest level's own resolution; the stronger ones, baked at a half
/// and a quarter, scaled up to it once at the bake — blended row by row into
/// the one image a `HeroBannerPictureView` shows (`composite`).
///
/// Immutable once baked, and read on the main thread only: the scratch rows
/// are the compositor's, which is why this is `@unchecked Sendable` — it
/// crosses from the bake's queue once, then stays.
final class HeroBannerBlurRows: @unchecked Sendable {
    /// The levels' size, in pixels — one per point of the picture as baked.
    let width: Int
    let height: Int
    private let levels: [vImage_Buffer]
    /// The operands a planar blend needs: the levels' alpha (they are
    /// opaque), a row of nothing, and two rows to read a slid picture into.
    private let opaqueRow: UnsafeMutableRawPointer
    private let clearRow: UnsafeMutableRawPointer
    private let lowerScratch: UnsafeMutableRawPointer
    private let upperScratch: UnsafeMutableRawPointer

    /// How close to one of the levels' rows a read must fall to take that
    /// row as it is rather than mix two: a sixth of a point, on levels
    /// blurred by a point and a half at the least.
    static let rowSnap: CGFloat = 0.15

    /// What the levels hold, in bytes.
    var byteCount: Int { levels.reduce(0) { $0 + $1.rowBytes * Int($1.height) } }

    init?(levels images: [UIImage]) {
        guard let format = HeroBannerFade.pixelFormat, let first = images.first?.cgImage else { return nil }
        var buffers: [vImage_Buffer] = []
        for image in images {
            guard let cgImage = image.cgImage,
                  var source = try? vImage_Buffer(cgImage: cgImage, format: format)
            else {
                buffers.forEach { $0.free() }
                return nil
            }
            if cgImage.width == first.width, cgImage.height == first.height {
                buffers.append(source)
                continue
            }
            defer { source.free() }
            guard var scaled = try? vImage_Buffer(width: first.width, height: first.height, bitsPerPixel: 32)
            else {
                buffers.forEach { $0.free() }
                return nil
            }
            guard vImageScale_ARGB8888(&source, &scaled, nil, vImage_Flags(kvImageEdgeExtend)) == kvImageNoError
            else {
                scaled.free()
                buffers.forEach { $0.free() }
                return nil
            }
            buffers.append(scaled)
        }
        width = first.width
        height = first.height
        levels = buffers
        func row(_ byte: UInt8) -> UnsafeMutableRawPointer {
            let row = UnsafeMutableRawPointer.allocate(byteCount: first.width * 4, alignment: 16)
            row.initializeMemory(as: UInt8.self, repeating: byte, count: first.width * 4)
            return row
        }
        opaqueRow = row(255)
        clearRow = row(0)
        lowerScratch = row(0)
        upperScratch = row(0)
    }

    deinit {
        levels.forEach { $0.free() }
        for row in [opaqueRow, clearRow, lowerScratch, upperScratch] { row.deallocate() }
    }

    /// The blurred run-out for `count` rows of one point each, the first at
    /// `top` in the banner's coordinates: every row the level `spans` fade
    /// in at its height, over the one before it, read from the picture's
    /// row behind it — the picture's top (slid by the parallax) at
    /// `pictureTop`, `rowPitch` points per row of the levels.
    ///
    /// What the masked stack drew, row for row: clear above the first span;
    /// over the first, the faintest level fading in over the sharp picture
    /// (premultiplied alpha — the sharp picture is drawn under it); below,
    /// opaque, each row two neighbouring levels at the row's weight. The
    /// rows are one point apart and the render server scales them up with a
    /// linear filter, which draws the linear climbs between them exactly.
    ///
    /// Only `columns` of the levels (all of them by default): the picture is
    /// aspect-filled, and a wide one reaches past the banner's sides — on a
    /// place, most of a row's cost was columns nobody sees (measured on
    /// `-place-scroll-sweep`: max 1.15ms a composition before the crop).
    func composite(
        rows count: Int, from top: CGFloat, spans: [(start: CGFloat, full: CGFloat)],
        pictureTop: CGFloat, rowPitch: CGFloat, columns: Range<Int>? = nil
    ) -> CGImage? {
        let columns = (columns ?? 0..<width).clamped(to: 0..<width)
        guard count > 0, rowPitch > 0, !spans.isEmpty, spans.count <= levels.count, !columns.isEmpty,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let output = try? vImage_Buffer(width: columns.count, height: count, bitsPerPixel: 32)
        else { return nil }
        let offset = columns.lowerBound * 4
        let length = columns.count * 4
        for row in 0..<count {
            let y = top + CGFloat(row) + 0.5
            let out = output.data + row * output.rowBytes
            guard let index = spans.lastIndex(where: { $0.start <= y }) else {
                out.copyMemory(from: clearRow, byteCount: length)
                continue
            }
            let span = spans[index]
            let weight = UInt8((255 * max(0, min((y - span.start) / max(span.full - span.start, 1), 1))).rounded())
            // The picture's row behind this one, in the levels' pixels.
            let source = (y - pictureTop) / rowPitch - 0.5
            let upper = read(index, at: source, from: offset, length: length, into: upperScratch)
            let lower = index == 0
                ? UnsafeRawPointer(clearRow)
                : read(index - 1, at: source, from: offset, length: length, into: lowerScratch)
            mix(upper, weight, over: lower, into: out, length: length)
        }
        guard let provider = CGDataProvider(
            dataInfo: nil, data: output.data, size: output.rowBytes * count,
            releaseData: { _, data, _ in free(UnsafeMutableRawPointer(mutating: data)) }
        ) else {
            output.free()
            return nil
        }
        return CGImage(
            width: columns.count, height: count, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: output.rowBytes,
            space: space,
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    /// Level `index`'s row at `source` (fractional: between two rows, the
    /// two mixed), `length` bytes from `offset`, or the row itself when it
    /// falls on one.
    private func read(
        _ index: Int, at source: CGFloat, from offset: Int, length: Int, into scratch: UnsafeMutableRawPointer
    ) -> UnsafeRawPointer {
        let level = levels[index]
        let clamped = max(0, min(source, CGFloat(height - 1)))
        let first = Int(clamped.rounded(.down))
        let second = min(first + 1, height - 1)
        let between = clamped - CGFloat(first)
        let here = UnsafeRawPointer(level.data + first * level.rowBytes + offset)
        guard between > Self.rowSnap, second != first else { return here }
        let next = UnsafeRawPointer(level.data + second * level.rowBytes + offset)
        guard between < 1 - Self.rowSnap else { return next }
        mix(next, UInt8((255 * between).rounded()), over: here, into: scratch, length: length)
        return UnsafeRawPointer(scratch)
    }

    /// `upper` at `weight` over `lower` — premultiplied, every byte alike,
    /// so the channel order does not matter: an opaque `upper` is the linear
    /// mix of the two, and over the clear row it is `upper` at `weight`.
    private func mix(
        _ upper: UnsafeRawPointer, _ weight: UInt8, over lower: UnsafeRawPointer, into out: UnsafeMutableRawPointer,
        length: Int
    ) {
        if weight == 0 { return out.copyMemory(from: lower, byteCount: length) }
        if weight == 255 { return out.copyMemory(from: upper, byteCount: length) }
        func row(_ pointer: UnsafeRawPointer) -> vImage_Buffer {
            vImage_Buffer(
                data: UnsafeMutableRawPointer(mutating: pointer), height: 1,
                width: vImagePixelCount(length), rowBytes: length
            )
        }
        var top = row(upper), alpha = row(opaqueRow), bottom = row(lower), destination = row(out)
        vImagePremultipliedConstAlphaBlend_Planar8(
            &top, weight, &alpha, &bottom, &destination, vImage_Flags(kvImageNoFlags)
        )
    }
}

/// A banner's picture with `HeroBannerFade`'s progressive blur: an
/// aspect-filled image, and over it the baked levels, each masked to where it
/// fades in. Pin it where the picture shows; give it the fade in its own
/// coordinates whenever layout moves the type (`fade`), and move the picture
/// inside it with `pictureOutset` / `pictureShift` — never by moving the view,
/// since the blur's climb belongs to the banner, not to the picture: a
/// parallax slides the picture UNDER a blur that stays with the type.
///
/// The levels are not layers: they are blended into ONE image, recomposed
/// whenever the picture slides (`HeroBannerBlurRows`) — see `HeroBannerFade`
/// for why six masked layers were too dear to scroll.
///
/// Fade it into the page with a `HeroBannerRampView` over it, in the same
/// coordinates.
public final class HeroBannerPictureView: UIView {
    /// The picture. Setting the same instance again does nothing.
    public var image: UIImage? {
        get { sharp.image }
        set {
            guard newValue !== sharp.image else { return }
            sharp.image = newValue
            baked = nil; baking = nil
            bake = nil
            hideBlur()
            setNeedsLayout()
        }
    }

    /// How far the picture reaches past this view's bounds — room for a
    /// parallax to slide it without uncovering an edge.
    public var pictureOutset: UIEdgeInsets = .zero {
        didSet { if pictureOutset != oldValue { setNeedsLayout() } }
    }

    /// How far down the picture is slid inside the view — the parallax. Moves
    /// the picture, and recomposes the blur from the rows that now stand
    /// behind its climb; the climb stays put.
    public var pictureShift: CGFloat = 0 {
        didSet {
            guard pictureShift != oldValue else { return }
            sharp.transform = CGAffineTransform(translationX: 0, y: pictureShift)
            composeBlur()
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
    /// The blurred run-out over the sharp picture: one image, the levels
    /// blended row by row (`composeBlur`). A plain view — no mask, nothing
    /// drawn offscreen.
    private let blur = UIView()
    /// The levels, as baked and as rows to blend.
    private var bake: HeroBannerFade.Bake?
    /// What the blur image on screen was composed for — so a layout pass or
    /// a scroll that moves nothing composes nothing.
    private struct Composition: Equatable {
        var top: CGFloat
        var rows: Int
        var fade: HeroBannerFade.Geometry
        var picture: CGRect
        var bake: ObjectIdentifier
    }
    private var composed: Composition?
    /// What the levels were baked for: the picture and its display scale.
    private var baked: (image: ObjectIdentifier, scale: CGFloat)?

    // MARK: - The ground under the type

    /// Called whenever the baked levels change — the moment a header can read
    /// the ground under its type and pick its ink (`HeroInk.tone`).
    public var onLevelsChanged: (() -> Void)?

    /// The tone the paired `HeroBannerRampView` fades the picture into — the
    /// page the header sits on. Only read here to tell the type what it
    /// stands on (`groundPixels`); the ramp draws it.
    public var pageTone: UIColor = Surface.page

    /// The ground behind `rect` (this view's coordinates) — the blurred
    /// picture with the page's tone over it as the ramp lays it, with the
    /// picture AT REST: the parallax is not the picture's to decide an ink
    /// by. Nil until the levels are baked.
    ///
    /// Read from the level that is WHOLE at the rect's top — the least
    /// blurred ground the block stands on, since the blur keeps climbing
    /// under the type down to the banner's foot (`HeroBannerFade`): an ink
    /// that holds over it holds over the blurrier rows below. Above the
    /// faintest level's full point, the faintest level stands in. Each row
    /// then takes the page's tone at its own height — ⚠️ the ramp climbs
    /// under the lower lines of a block, and an ink picked from the picture
    /// alone would be white on a light page's arriving tone. Read on
    /// demand, only the rect's pixels, so nothing is kept between bakes.
    public func groundPixels(behind rect: CGRect) -> [SIMD3<Float>]? {
        guard baked != nil, let levels = bake?.levels, let fade else { return nil }
        let spans = HeroBannerFade.levelSpans(fade)
        let shown = levels.indices.last { $0 < spans.count && spans[$0].full <= rect.minY } ?? 0
        guard let image = levels[shown].cgImage,
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
        var tone = (r: CGFloat(0), g: CGFloat(0), b: CGFloat(0), a: CGFloat(0))
        pageTone.resolvedColor(with: traitCollection).getRed(&tone.r, green: &tone.g, blue: &tone.b, alpha: &tone.a)
        let page = SIMD3(Float(tone.r), Float(tone.g), Float(tone.b))
        var pixels: [SIMD3<Float>] = []
        pixels.reserveCapacity(width * height)
        for row in 0..<height {
            // The row's middle, back in this view's space: the crop's rows
            // run top-down from `pixelRect`'s, `scale` points apart.
            let y = origin.y + (pixelRect.minY + CGFloat(row) + 0.5) * scale
            let alpha = Float(HeroBannerFade.rampAlpha(at: y, geometry: fade))
            for column in 0..<width {
                let index = (row * width + column) * 4
                let picture = SIMD3(
                    Float(bytes[index]) / 255, Float(bytes[index + 1]) / 255, Float(bytes[index + 2]) / 255
                )
                pixels.append(picture + (page - picture) * alpha)
            }
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
        blur.isUserInteractionEnabled = false
        blur.isHidden = true
        blur.layer.contentsGravity = .resize
        addSubview(blur)
        // The page's tone is part of the ground (`groundPixels`): a flip of
        // the appearance is a new ground, to be read again like a new bake.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: HeroBannerPictureView, _) in
            guard self.baked != nil else { return }
            self.onLevelsChanged?()
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
        composeBlur()
        #if DEBUG
        layoutMaterialComparison()
        traceLayout()
        #endif
    }

    /// The levels' climb over the view, as the spans that can show — each
    /// fading in from where it starts — or none before a bake or a fade.
    private var shownSpans: [(start: CGFloat, full: CGFloat)] {
        guard bake != nil, let fade, bounds.height > 0 else { return [] }
        return HeroBannerFade.levelSpans(fade).filter { $0.start < bounds.height }
    }

    /// Blends the levels into the blur image for where the picture stands
    /// now — the rows from the climb's top to the view's foot, each read
    /// from the picture's row behind it (`HeroBannerBlurRows.composite`).
    ///
    /// Runs on layout and on every change of `pictureShift`: a few hundred
    /// rows of vImage blends and one image handed to the render server —
    /// measured by `HeroScrollFrameProbe` on the scripted scrolls.
    private func composeBlur() {
        #if DEBUG
        if Self.comparesMaterial { return hideBlur() }
        #endif
        let spans = shownSpans
        guard let bake, let fade, let image = sharp.image, let first = spans.first,
              image.size.width > 0, image.size.height > 0
        else { return hideBlur() }
        let top = max(0, first.start.rounded(.down))
        let rows = Int((bounds.height - top).rounded(.up))
        // The picture as it stands — aspect-filled into its frame, slid by
        // the parallax — which the levels cover edge to edge.
        let frame = pictureFrame
        let fill = max(frame.width / image.size.width, frame.height / image.size.height)
        let picture = CGRect(
            x: frame.midX - image.size.width * fill / 2, y: frame.midY - image.size.height * fill / 2,
            width: image.size.width * fill, height: image.size.height * fill
        )
        let composition = Composition(
            top: top, rows: rows, fade: fade, picture: picture, bake: ObjectIdentifier(bake.rows)
        )
        guard composition != composed else { return }
        #if DEBUG
        let began = CACurrentMediaTime()
        defer { HeroScrollFrameProbe.recordCompose((CACurrentMediaTime() - began) * 1000, rows: rows) }
        #endif
        // Only the columns inside the view (a pixel of margin either side
        // for the linear filter): an aspect-filled picture overhangs it.
        let columnPitch = picture.width / CGFloat(bake.rows.width)
        let columns = max(0, Int(((0 - picture.minX) / columnPitch).rounded(.down)) - 1)
            ..< min(bake.rows.width, Int(((bounds.width - picture.minX) / columnPitch).rounded(.up)) + 1)
        // ⚠️ THE ROWS FOLLOW THE PICTURE'S, a fraction of a point below
        // `top`. Laid on whole points, a parallax that slid the picture by a
        // fraction read every row BETWEEN two of the levels' — two more
        // blends a row, most of the cost (0.64ms a composition on a poster,
        // measured). Phased so the middle row reads a level row exactly, the
        // others land within `HeroBannerBlurRows.rowSnap` of one (a level
        // row is a point give or take the bake's rounding) and are read as
        // they are — the weights still taken at each row's own height. A
        // banner stretched by a pull drifts further; there rows are mixed.
        let rowPitch = picture.height / CGFloat(bake.rows.height)
        let middle = CGFloat(rows / 2)
        let source = (top + middle + 0.5 - picture.minY) / rowPitch - 0.5
        let start = top + (source.rounded(.up) - source) * rowPitch
        guard rows > 0, !columns.isEmpty, let composite = bake.rows.composite(
            rows: rows + 1, from: start, spans: spans,
            pictureTop: picture.minY, rowPitch: rowPitch, columns: columns
        ) else { return hideBlur() }
        composed = composition
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        UIView.performWithoutAnimation {
            blur.layer.contents = composite
            blur.frame = CGRect(
                x: picture.minX + CGFloat(columns.lowerBound) * columnPitch, y: start,
                width: CGFloat(columns.count) * columnPitch, height: CGFloat(rows + 1)
            )
            blur.isHidden = false
        }
        CATransaction.commit()
    }

    private func hideBlur() {
        composed = nil
        blur.isHidden = true
        blur.layer.contents = nil
    }

    #if DEBUG
    private static let tracesBlur = ProcessInfo.processInfo.arguments.contains("-hero-blur-trace")
    private var lastLayoutTrace = ""

    /// `-hero-blur-trace`: one line whenever what the levels show changes —
    /// how many are up, over what fade, baked or baking, on screen or not.
    private func traceLayout() {
        guard Self.tracesBlur else { return }
        let shown = blur.isHidden ? 0 : shownSpans.count
        let levels = HeroBannerFade.blurSigmas
        let line = String(
            format: "HERO-BLUR layout %.0fx%.0f fade=%@ baked=%@ baking=%@ window=%@ shown=%d/%d",
            bounds.width, bounds.height,
            fade.map { String(format: "%.0f…%.0f ramp %.0f…%.0f", $0.blurStart, $0.blurFull, $0.rampStart, $0.rampEnd) }
                ?? "nil",
            baked == nil ? "no" : "yes", baking == nil ? "no" : "yes", window == nil ? "no" : "yes",
            shown, levels.count
        )
        guard line != lastLayoutTrace else { return }
        lastLayoutTrace = line
        print(line)
    }
    /// `-hero-blur-material`: the public-API alternative this view rejected —
    /// one `UIVisualEffectView` blur under a gradient mask over the same
    /// climb — in place of the baked levels, for side-by-side screenshots.
    /// Never shipped: its tint is the frost `HeroBannerFade` explains.
    private static let comparesMaterial = ProcessInfo.processInfo.arguments.contains("-hero-blur-material")
    private var material: (view: UIVisualEffectView, mask: CAGradientLayer)?

    private func layoutMaterialComparison() {
        guard Self.comparesMaterial, let fade, bounds.height > 0 else { return }
        hideBlur()
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
        guard isInVisibleWindow else {
            let began = CACurrentMediaTime()
            guard let bake = HeroBannerFade.bake(of: image, displayScale: scale) else { return }
            adopt(bake, for: key, size: size, milliseconds: (CACurrentMediaTime() - began) * 1000)
            return
        }
        baking = key
        DispatchQueue.global(qos: .userInitiated).async {
            let began = CACurrentMediaTime()
            let bake = HeroBannerFade.bake(of: image, displayScale: scale)
            let milliseconds = (CACurrentMediaTime() - began) * 1000
            DispatchQueue.main.async { [weak self] in
                guard let self, let baking = self.baking, baking.image == key.0, baking.scale == key.1
                else { return }
                self.baking = nil
                guard let bake, self.sharp.image.map(ObjectIdentifier.init) == key.0 else { return }
                UIView.transition(
                    with: self, duration: 0.2, options: [.transitionCrossDissolve, .allowUserInteraction]
                ) {
                    self.adopt(bake, for: key, size: size, milliseconds: milliseconds)
                    self.layoutIfNeeded()
                }
            }
        }
    }

    private func adopt(
        _ bake: HeroBannerFade.Bake, for key: (image: ObjectIdentifier, scale: CGFloat), size: CGSize,
        milliseconds: Double
    ) {
        #if DEBUG
        debugLastBakeMilliseconds = milliseconds
        // The levels as baked and as rows — the rows are most of it: six
        // levels at the faintest one's resolution.
        debugLastBakeBytes = bake.rows.byteCount + bake.levels.reduce(0) { total, level in
            total + (level.cgImage.map { $0.bytesPerRow * $0.height } ?? 0)
        }
        if ProcessInfo.processInfo.arguments.contains("-hero-blur-trace") {
            print(String(
                format: "HERO-BLUR baked %d levels for %.0fx%.0fpt in %.1fms (%@), %.0f KB",
                bake.levels.count, size.width, size.height, milliseconds,
                window == nil ? "in place" : "background", Double(debugLastBakeBytes) / 1024
            ))
        }
        #endif
        baked = key
        self.bake = bake
        setNeedsLayout()
        onLevelsChanged?()
    }

    #if DEBUG
    /// The last bake's cost, for the trace and the tests.
    public private(set) var debugLastBakeMilliseconds: Double = 0
    public private(set) var debugLastBakeBytes = 0
    /// The levels showing, and where each one fades in, in this view's
    /// space — clamped to the view, as a mask's stops were.
    public var debugVisibleLevels: [(start: CGFloat, full: CGFloat)] {
        guard !blur.isHidden else { return [] }
        func clamp(_ y: CGFloat) -> CGFloat { max(0, min(y, bounds.height)) }
        return shownSpans.map { (clamp($0.start), clamp(max($0.full, $0.start + 1))) }
    }
    #endif
}

/// The page's tone climbing a `HeroBannerPictureView` — the picture's fade
/// into the page, `HeroBannerFade`'s ramp. Pin it over the picture in the
/// same coordinates and hand it the same `fade` (and, if it is not the
/// page's, the same tone as the picture's `pageTone`).
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

public extension UIView {
    /// Whether anyone can see this view's frames: it is in a window, and
    /// the window is not hidden. What decides between doing a picture-led
    /// header's work in place (a header being built, a test) and doing it
    /// the on-screen way (a background bake, a dissolve).
    ///
    /// ⚠️ NOT `window != nil`: a unit test hosts the header in a HIDDEN
    /// window, because off a window the test host ignores
    /// `overrideUserInterfaceStyle` — every view reports the simulator's
    /// own appearance (measured, iOS 27: a `.dark` override read back
    /// `.light`), so a "dark" ink test was drawing and reading the light
    /// page. A hidden window carries the override, and nobody sees its
    /// frames.
    var isInVisibleWindow: Bool {
        guard let window else { return false }
        return !window.isHidden
    }
}

/// An image view sized by its constraints or frame only: a loaded bitmap's
/// intrinsic size must not vote (see the profile header's no-intrinsic-image
/// rule).
private final class FillImageView: UIImageView {
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }
}
