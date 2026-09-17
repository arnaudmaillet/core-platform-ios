import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Puts a `FrameLook` through a picture, as a Core Image graph.
///
/// ⚠️ **IT BUILDS A GRAPH AND RENDERS NOTHING.** The photo path renders once at
/// the end of crop → look → overlays, and the compositor renders once into its
/// output buffer; a renderer that drew its own result would cost a round trip
/// per stage.
///
/// ⚠️ **A NEW `CIFilter` ON EVERY CALL.** `CIFilter` is not `Sendable` (`CIImage`
/// and `CIContext` are), and this runs on the main actor's detached renders and
/// on the compositor's queue alike. A filter kept in a static would be shared
/// state with no lock.
///
/// ⚠️ **THE SAME PICTURE UNDER BOTH CONTEXTS — BY CONSTRUCTION, NOT BY LUCK.**
/// The photo path renders through a managed sRGB context, whose working space
/// is LINEAR light; the compositor renders through an unmanaged one
/// (`VideoCompositor.context`), where a filter reads the encoded values
/// themselves. Most built-in filters just do arithmetic on whatever they are
/// handed, so the same dial drew two different pictures — on one 64×64
/// picture brightness +0.1 lifted a dark grey to 97 managed and 64 unmanaged,
/// posterize differed by up to 102, a vignette by 73, thermal by 255; in the
/// simulator the whole look of `aLookDrawsTheSameOnBothSurfaces` drew 111
/// apart. So every stage that is plain arithmetic runs inside `perceptual`, which
/// hands it ENCODED values under the managed context and is a no-op under the
/// unmanaged one: measured on the simulator, the two contexts then drew the
/// whole look identically (`FrameLookRendererTests` allows a few units). The
/// exceptions manage colour THEMSELVES and must stay outside — the
/// `CIPhotoEffect` presets and `CIColorCurves` convert to their own space
/// internally, drew identically under both contexts raw, and drew up to 80
/// apart once wrapped.
///
/// ⚠️ **EVERY STAGE HANDS ON THE EXTENT IT WAS GIVEN.** `CIRandomGenerator`
/// and `CIStripesGenerator` are infinite, a colour matrix with an alpha bias
/// makes the nothing around a picture opaque, and every neighbourhood filter —
/// blurs, pixellate, crystallize, bloom, comic — draws past the edge
/// (measured: a 64-point picture came back up to 94 wide). Left uncropped, the
/// next stage would centre its vignette on the wrong point and the photo path
/// would render a bigger picture than it was given. So each stage that can
/// spread is cropped once, at its end — the effect's recipes all at once, as
/// they enter the mix — and the filters that only recolour are not cropped at
/// all. Filters that read neighbours are handed `clampedToExtent()`, so an
/// edge is not darkened by the transparent nothing beyond it.
///
/// The measurements quoted in these notes were taken with Core Image on the
/// Mac that runs the simulator, unless they say "in the simulator".
public enum FrameLookRenderer {
    /// `image` wearing `look`, at `time` seconds (time-based stages such as
    /// grain move with it; a photograph passes 0).
    ///
    /// Applied in this order: the dials (brightness, contrast, saturation,
    /// warmth), highlights and shadows, the preset, the effect (mixed with what
    /// came before it by its intensity), sharpness, vignette, grain. Grain and
    /// vignette come last so nothing blurs or recolours them.
    ///
    /// A neutral look returns `image` itself — the same object — and each stage
    /// is skipped while its part of the look is neutral. A picture with no
    /// finite, non-empty extent is returned as it is: every stage past the
    /// preset places itself within the extent.
    public static func apply(_ look: FrameLook, to image: CIImage, time: Double) -> CIImage {
        guard !look.isNeutral else { return image }
        let extent = image.extent
        guard !extent.isInfinite, !extent.isEmpty else { return image }

        let dials = look.adjustments
        var picture = colour(dials, on: image)
        picture = tone(dials, on: picture)
        picture = preset(look.preset, on: picture)

        let finishes = look.effect != nil || dials.sharpness > 0 || dials.vignette > 0 || dials.grain > 0
        guard finishes else { return picture }
        return perceptual(picture) { encoded in
            var finished = encoded
            if let effect = look.effect {
                finished = Self.effect(effect, on: finished, in: extent, at: time)
            }
            if dials.sharpness > 0 {
                finished = sharpened(finished, by: dials.sharpness, in: extent)
            }
            if dials.vignette > 0 {
                finished = vignetted(finished, by: dials.vignette, in: extent)
            }
            if dials.grain > 0 {
                finished = grained(finished, by: dials.grain, amplitude: grainAmplitude, at: time, in: extent)
            }
            return finished
        }
    }

    // MARK: - Tuning

    /// How far a whole dial moves each control. Brightness adds at most a fifth
    /// of white; contrast scales about mid-grey by half again at most.
    private static let brightnessReach = 0.2
    private static let contrastReach = 0.5

    /// Warmth moves the white point this fraction of its MIRED value either
    /// way — mireds rather than kelvin, because a kelvin step means far more at
    /// the cool end than the warm one. At ±1 the neutral is about 9,300K and
    /// 5,000K.
    ///
    /// ⚠️ **THE DIRECTION IS MEASURED, AND IT IS THE COUNTER-INTUITIVE ONE.**
    /// Telling `CITemperatureAndTint` that the picture's neutral is HOTTER than
    /// its target warms the picture (red up, blue down); lowering it cools.
    /// `warmthRaisesRedAndLowersBlue` pins it.
    private static let warmthReach = 0.3
    private static let daylight = 6500.0

    /// The most a highlights or shadows dial moves the middle of its range.
    ///
    /// ⚠️ **NOT `CIHighlightShadowAdjust`, WHICH CANNOT BRIGHTEN A HIGHLIGHT.**
    /// Measured: `highlightAmount` 1.7 and 2 drew exactly what 1 draws, so half
    /// of the highlights dial would have done nothing; and `shadowAmount` +1
    /// dragged the MID-tones up too (a quarter grey to 137 of 255, half grey to
    /// 171), which is no longer "shadows". A one-dimensional curve does both
    /// directions of both dials, touches only its own half of the range, and is
    /// a single table look-up. Kept under 0.148 so the curve can never fold
    /// back on itself (its steepest weight has a slope of 6.75).
    private static let toneReach = 0.14

    /// How strongly grain speckles a picture at its full dial: the spread of the
    /// noise around mid-grey before the soft-light blend.
    private static let grainAmplitude: CGFloat = 0.4

    /// ⚠️ **ABOVE THIS RADIUS, A BLUR IS DRAWN AT A QUARTER OF THE SIZE.** The
    /// iPhone SE has about 25 ms for a whole preview frame, and a blur that wide
    /// has no detail left for the lost resolution to show. Measured on a
    /// 1280×720 frame in the simulator: the full-size 21.6-pixel blur touched
    /// 3.22 million pixels, the quarter-size one 1.99 million, and the two drew
    /// within 1 of 255 of each other at radius 12.
    /// `aWideBlurCostsLessThanAFullSizeOne` pins that the path is taken.
    ///
    /// ⚠️ **NOT BECAUSE `CIGaussianBlur` GROWS WITH ITS RADIUS — IT BARELY
    /// DOES.** Core Image already blurs in several passes of its own: 7.9 and
    /// 21.6 pixels touched the same 3.22 million. Starting at a quarter of the
    /// size is what still saves a third of that.
    static let blurDownsamplesAbove = 8.0

    // MARK: - Colour spaces

    /// Runs `body` on ENCODED values, whichever context renders the result.
    ///
    /// ⚠️ **`matchedFromWorkingSpace` IS A NO-OP UNDER AN UNMANAGED CONTEXT —
    /// MEASURED — AND THAT IS THE POINT.** Under the photo context the picture is
    /// converted from linear light to sRGB for `body` and back afterwards; under
    /// the compositor's context, whose working space is none, both conversions
    /// vanish and `body` reads the Rec. 709 values the frame carries. Either way
    /// the filters see gamma-encoded values, which is what their parameters were
    /// tuned for.
    ///
    /// ⚠️ **EXTENDED sRGB, SO A WIDE-GAMUT PHOTOGRAPH IS NOT CLIPPED** on its way
    /// through; for every colour sRGB can hold the two are the same.
    ///
    /// ⚠️ **ONLY FILTERS THAT DO PLAIN ARITHMETIC BELONG INSIDE** — see the type
    /// comment. And a colour handed to a filter in here (`CIColor`) would be
    /// matched to the working space on its own, so the only colours used inside
    /// are black and white, which every space agrees on.
    private static func perceptual(_ image: CIImage, _ body: (CIImage) -> CIImage) -> CIImage {
        guard let space = CGColorSpace(name: CGColorSpace.extendedSRGB),
              let encoded = image.matchedFromWorkingSpace(to: space)
        else { return body(image) }
        let drawn = body(encoded)
        return drawn.matchedToWorkingSpace(from: space) ?? drawn
    }

    // MARK: - The dials

    /// Brightness, contrast and saturation in one `CIColorControls`, then
    /// warmth.
    private static func colour(_ dials: LookAdjustments, on image: CIImage) -> CIImage {
        let controls = dials.brightness != 0 || dials.contrast != 0 || dials.saturation != 0
        guard controls || dials.warmth != 0 else { return image }
        return perceptual(image) { encoded in
            var picture = encoded
            if controls {
                let filter = CIFilter.colorControls()
                filter.inputImage = picture
                filter.brightness = Float(dials.brightness * brightnessReach)
                filter.contrast = Float(1 + dials.contrast * contrastReach)
                filter.saturation = Float(1 + dials.saturation)
                picture = filter.outputImage ?? picture
            }
            if dials.warmth != 0 {
                let mired = 1_000_000 / daylight * (1 - warmthReach * dials.warmth)
                let filter = CIFilter.temperatureAndTint()
                filter.inputImage = picture
                filter.neutral = CIVector(x: 1_000_000 / mired, y: 0)
                filter.targetNeutral = CIVector(x: daylight, y: 0)
                picture = filter.outputImage ?? picture
            }
            return picture
        }
    }

    /// Highlights and shadows, as one curve over the encoded range.
    ///
    /// ⚠️ **OUTSIDE `perceptual`, BECAUSE `CIColorCurves` MANAGES ITS OWN
    /// COLOUR.** Its table is applied in `colorSpace`, converted to and from the
    /// working space internally — measured, it drew identically under both
    /// contexts as it is, and 26 apart once wrapped.
    private static func tone(_ dials: LookAdjustments, on image: CIImage) -> CIImage {
        guard dials.highlights != 0 || dials.shadows != 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return image }
        let filter = CIFilter.colorCurves()
        filter.inputImage = image
        filter.curvesData = toneTable(shadows: dials.shadows, highlights: dials.highlights)
        filter.curvesDomain = CIVector(x: 0, y: 1)
        filter.colorSpace = space
        return filter.outputImage ?? image
    }

    /// The curve `tone` applies: the identity, plus a bump peaking a third of
    /// the way up for shadows and two thirds of the way up for highlights. Each
    /// bump is zero at black and at white, so neither dial moves either end.
    private static func toneTable(shadows: Double, highlights: Double) -> Data {
        let count = 64
        var values: [Float] = []
        values.reserveCapacity(count * 3)
        for index in 0..<count {
            let x = Double(index) / Double(count - 1)
            let low = 6.75 * x * (1 - x) * (1 - x)
            let high = 6.75 * x * x * (1 - x)
            let y = Float(min(max(x + toneReach * (shadows * low + highlights * high), 0), 1))
            values.append(contentsOf: [y, y, y])
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // MARK: - The preset

    /// The preset stage: one of Apple's `CIPhotoEffect` looks, or the picture
    /// itself for `.original`.
    ///
    /// ⚠️ **THE TYPED SPELLINGS, NOT `CIFilter(name:)`.** The eight names were
    /// read out of this SDK's `CIFilterBuiltins.h`; a string turns a typo into a
    /// crash at run time.
    ///
    /// ⚠️ **OUTSIDE `perceptual`** — the presets manage their own colour (see
    /// the type comment).
    private static func preset(_ preset: LookPreset, on image: CIImage) -> CIImage {
        let filter: (CIFilter & CIPhotoEffect)?
        switch preset {
        case .original: filter = nil
        case .chrome: filter = CIFilter.photoEffectChrome()
        case .fade: filter = CIFilter.photoEffectFade()
        case .instant: filter = CIFilter.photoEffectInstant()
        case .mono: filter = CIFilter.photoEffectMono()
        case .noir: filter = CIFilter.photoEffectNoir()
        case .process: filter = CIFilter.photoEffectProcess()
        case .tonal: filter = CIFilter.photoEffectTonal()
        case .transfer: filter = CIFilter.photoEffectTransfer()
        }
        guard let filter else { return image }
        filter.inputImage = image
        return filter.outputImage ?? image
    }

    // MARK: - The effect

    /// `effect` drawn over `image`, then mixed with it by the effect's
    /// intensity.
    ///
    /// Sizes are fractions of the picture, never pixels, so the preview at 1280
    /// and the export at 1920 wear the same effect. Four recipes also grow with
    /// the intensity before the mix: the blur's radius, the pixellation's cells,
    /// the RGB split's distance and posterize's coarseness.
    ///
    /// ⚠️ **THE MIX IS WHAT MAKES A LOW INTENSITY LOW.** Without it, a comic
    /// effect at 1% is the whole comic effect; `zeroIntensityIsTheSource` reads
    /// a hair above zero for every kind.
    ///
    /// ⚠️ **A RECIPE MAY DRAW PAST THE PICTURE; THE MIX'S INPUT IS WHERE IT IS
    /// CROPPED, ONCE, FOR ALL TWELVE.** The mix of two pictures covers both, so
    /// an uncropped recipe would hand the next stage an infinite one.
    private static func effect(
        _ effect: LookEffect, on image: CIImage, in extent: CGRect, at time: Double
    ) -> CIImage {
        let intensity = effect.intensity
        let short = min(extent.width, extent.height)
        let centre = CGPoint(x: extent.midX, y: extent.midY)
        let drawn: CIImage?
        switch effect.kind {
        case .blur:
            drawn = blurred(image, radius: intensity * 0.03 * short)
        case .pixellate:
            let filter = CIFilter.pixellate()
            filter.inputImage = image.clampedToExtent()
            filter.center = centre
            filter.scale = Float(max(2, intensity * 0.05 * extent.width))
            drawn = filter.outputImage
        case .rgbSplit:
            drawn = split(image, by: intensity * 0.012 * extent.width)
        case .vhs:
            drawn = taped(image, in: extent, at: time)
        case .posterize:
            let filter = CIFilter.colorPosterize()
            filter.inputImage = image
            filter.levels = Float(30 - 26 * intensity)
            drawn = filter.outputImage
        case .comic:
            let filter = CIFilter.comicEffect()
            filter.inputImage = image.clampedToExtent()
            drawn = filter.outputImage
        case .bloom:
            let filter = CIFilter.bloom()
            filter.inputImage = image.clampedToExtent()
            filter.radius = Float(max(2, 0.02 * short))
            filter.intensity = 1
            drawn = filter.outputImage
        case .zoomBlur:
            let filter = CIFilter.zoomBlur()
            filter.inputImage = image.clampedToExtent()
            filter.center = centre
            filter.amount = Float(0.03 * short)
            drawn = filter.outputImage
        case .crystallize:
            let filter = CIFilter.crystallize()
            filter.inputImage = image.clampedToExtent()
            filter.center = centre
            filter.radius = Float(max(2, 0.02 * short))
            drawn = filter.outputImage
        case .halftone:
            let filter = CIFilter.dotScreen()
            filter.inputImage = image
            filter.center = centre
            filter.width = Float(max(3, 0.01 * short))
            drawn = filter.outputImage
        case .thermal:
            let filter = CIFilter.thermal()
            filter.inputImage = image
            drawn = filter.outputImage
        case .xray:
            let filter = CIFilter.xRay()
            filter.inputImage = image
            drawn = filter.outputImage
        }
        guard let drawn else { return image }
        let mix = CIFilter.mix()
        mix.inputImage = drawn.cropped(to: extent)
        mix.backgroundImage = image
        mix.amount = Float(intensity)
        return mix.outputImage ?? image
    }

    /// A Gaussian blur that does not darken the edges, drawn at a quarter of
    /// the size once it is wider than `blurDownsamplesAbove`. Infinite: the
    /// caller crops.
    private static func blurred(_ image: CIImage, radius: Double) -> CIImage {
        let clamped = image.clampedToExtent()
        func gaussian(_ source: CIImage, _ radius: Double) -> CIImage {
            let filter = CIFilter.gaussianBlur()
            filter.inputImage = source
            filter.radius = Float(radius)
            return filter.outputImage ?? source
        }
        guard radius > blurDownsamplesAbove else { return gaussian(clamped, radius) }
        let quarter = CGAffineTransform(scaleX: 0.25, y: 0.25)
        return gaussian(clamped.transformed(by: quarter), radius / 4)
            .transformed(by: quarter.inverted())
    }

    /// The red channel moved `distance` pixels right, the blue one moved left,
    /// green in place, laid back together. Infinite: the caller crops.
    ///
    /// ⚠️ **JOINED BY THEIR MAXIMUM, NOT ADDED.** Each channel's picture is
    /// opaque, and `CIAdditionCompositing` adds the alphas too: measured, the
    /// joined picture carried an alpha of 3. An 8-bit render clamps that away,
    /// so the split alone looked right — and the grain blended over it came out
    /// BLACK. Each picture holds one channel and zeros elsewhere, so the
    /// maximum joins the colours exactly and keeps the alpha at one.
    private static func split(_ image: CIImage, by distance: CGFloat) -> CIImage {
        let clamped = image.clampedToExtent()
        func channel(red: CGFloat, green: CGFloat, blue: CGFloat, shift: CGFloat) -> CIImage {
            let filter = CIFilter.colorMatrix()
            filter.inputImage = clamped
            filter.rVector = CIVector(x: red, y: 0, z: 0, w: 0)
            filter.gVector = CIVector(x: 0, y: green, z: 0, w: 0)
            filter.bVector = CIVector(x: 0, y: 0, z: blue, w: 0)
            filter.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            let only = filter.outputImage ?? clamped
            return shift == 0 ? only : only.transformed(by: CGAffineTransform(translationX: shift, y: 0))
        }
        func joined(_ top: CIImage, _ bottom: CIImage) -> CIImage {
            let filter = CIFilter.maximumCompositing()
            filter.inputImage = top
            filter.backgroundImage = bottom
            return filter.outputImage ?? bottom
        }
        let red = channel(red: 1, green: 0, blue: 0, shift: distance)
        let green = channel(red: 0, green: 1, blue: 0, shift: 0)
        let blue = channel(red: 0, green: 0, blue: 1, shift: -distance)
        return joined(red, joined(green, blue))
    }

    /// An old tape: a slight colour split, washed-out colour, a horizontal
    /// smear, dark scanlines and moving noise. Infinite: the caller crops.
    ///
    /// The smear reads the split as it is, unclamped: the split was drawn from
    /// a clamped picture, so it is already the picture's edge all the way out.
    private static func taped(_ image: CIImage, in extent: CGRect, at time: Double) -> CIImage {
        var picture = split(image, by: 0.004 * extent.width)

        let washed = CIFilter.colorControls()
        washed.inputImage = picture
        washed.saturation = 0.8
        washed.brightness = 0
        washed.contrast = 1
        picture = washed.outputImage ?? picture

        let smear = CIFilter.motionBlur()
        smear.inputImage = picture
        smear.radius = Float(max(1, 0.002 * extent.width))
        smear.angle = 0
        picture = smear.outputImage ?? picture

        picture = scanned(picture, in: extent)
        return grained(picture, by: 1, amplitude: 0.6, at: time, in: extent)
    }

    /// Dark horizontal lines, one line pair per 180th of the height. Infinite:
    /// the caller crops.
    ///
    /// ⚠️ **THE STRIPES ARE WHITE AND BLACK, AND DIMMED BY A MATRIX.** A grey
    /// `CIColor` handed to the generator would be colour-matched on its own —
    /// linear under the photo context, left alone under the video one — and the
    /// two would draw different lines (see `perceptual`).
    ///
    /// ⚠️ **SWAPPED, NOT ROTATED.** The generator draws vertical stripes; the
    /// matrix that swaps x and y lays them flat exactly, where a quarter-turn
    /// rotation would resample them through a cosine that is not quite zero.
    private static func scanned(_ image: CIImage, in extent: CGRect) -> CIImage {
        let halfPeriod = max(1, (extent.height / 360).rounded())
        let stripes = CIFilter.stripesGenerator()
        stripes.center = extent.origin
        stripes.color0 = CIColor(red: 1, green: 1, blue: 1)
        stripes.color1 = CIColor(red: 0, green: 0, blue: 0)
        stripes.width = Float(halfPeriod)
        stripes.sharpness = 1
        guard let vertical = stripes.outputImage else { return image }
        let flat = vertical.transformed(by: CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0))

        let dim = CIFilter.colorMatrix()
        dim.inputImage = flat
        dim.rVector = CIVector(x: -0.3, y: 0, z: 0, w: 0)
        dim.gVector = CIVector(x: 0, y: -0.3, z: 0, w: 0)
        dim.bVector = CIVector(x: 0, y: 0, z: -0.3, w: 0)
        dim.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        dim.biasVector = CIVector(x: 1, y: 1, z: 1, w: 1)
        guard let lines = dim.outputImage else { return image }

        let multiply = CIFilter.multiplyCompositing()
        multiply.inputImage = lines
        multiply.backgroundImage = image
        return multiply.outputImage ?? image
    }

    // MARK: - The finishing dials

    private static func sharpened(_ image: CIImage, by amount: Double, in extent: CGRect) -> CIImage {
        let filter = CIFilter.sharpenLuminance()
        filter.inputImage = image.clampedToExtent()
        filter.sharpness = Float(amount * 1.2)
        return (filter.outputImage ?? image).cropped(to: extent)
    }

    /// Darker towards the corners.
    ///
    /// ⚠️ **SIZED BY THE PICTURE, NOT IN PIXELS.** The radius is half the
    /// diagonal, so the 1280-pixel preview and the 1920-pixel export darken the
    /// same share of the frame; a radius in points would darken a small picture
    /// less than a large one. `vignetteDarkensCornersNotCentre` reads both
    /// sizes.
    private static func vignetted(_ image: CIImage, by amount: Double, in extent: CGRect) -> CIImage {
        let filter = CIFilter.vignetteEffect()
        filter.inputImage = image
        filter.center = CGPoint(x: extent.midX, y: extent.midY)
        filter.radius = Float(hypot(extent.width, extent.height) / 2)
        filter.intensity = Float(amount)
        filter.falloff = 0.5
        return filter.outputImage ?? image
    }

    /// Film grain: monochrome noise, soft-light blended, then mixed in by
    /// `amount`.
    ///
    /// ⚠️ **THE NOISE MOVES WITH TIME.** Grain that stood still on a playing
    /// video would read as dirt on the lens. The noise texture is slid by an
    /// amount that changes every frame — whole pixels, because a fractional
    /// slide would interpolate the noise into mush — and a photograph, at
    /// time 0, always wears the same grain.
    ///
    /// ⚠️ **ALPHA SET TO ONE BEFORE THE MATRIX.** `CIRandomGenerator` randomises
    /// all four channels, and `CIColorMatrix` un-premultiplies first: measured,
    /// the "mid-grey" noise then averaged 181 of 255 instead of 127.
    ///
    /// ⚠️ **THE GRAIN IS CROPPED, AND ONLY THE GRAIN.** The matrix's alpha bias
    /// makes it opaque everywhere, so uncropped it would stretch the picture to
    /// infinity; blended over a bounded picture it stays bounded.
    private static func grained(
        _ image: CIImage, by amount: Double, amplitude: CGFloat, at time: Double, in extent: CGRect
    ) -> CIImage {
        guard let noise = CIFilter.randomGenerator().outputImage else { return image }
        let slide = CGAffineTransform(
            translationX: (time * 997).truncatingRemainder(dividingBy: 512).rounded(),
            y: (time * 613).truncatingRemainder(dividingBy: 512).rounded()
        )
        let grey = CIFilter.colorMatrix()
        grey.inputImage = noise.transformed(by: slide).settingAlphaOne(in: extent)
        grey.rVector = CIVector(x: amplitude, y: 0, z: 0, w: 0)
        grey.gVector = CIVector(x: amplitude, y: 0, z: 0, w: 0)
        grey.bVector = CIVector(x: amplitude, y: 0, z: 0, w: 0)
        grey.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        let middle = 0.5 - amplitude / 2
        grey.biasVector = CIVector(x: middle, y: middle, z: middle, w: 1)
        guard let grain = grey.outputImage?.cropped(to: extent) else { return image }

        let blend = CIFilter.softLightBlendMode()
        blend.inputImage = grain
        blend.backgroundImage = image
        guard let speckled = blend.outputImage else { return image }
        guard amount < 1 else { return speckled }

        let mix = CIFilter.mix()
        mix.inputImage = speckled
        mix.backgroundImage = image
        mix.amount = Float(amount)
        return mix.outputImage ?? image
    }
}
