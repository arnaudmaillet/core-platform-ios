import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Testing
@testable import MediaPlayback

/// **A LOOK IS PIXELS, AND THE SAME PIXELS ON A PHOTO AND ON A VIDEO.**
///
/// Every assertion reads what a context DREW from `FrameLookRenderer`'s graph —
/// never the graph itself — and every pixel test runs under both the photo
/// path's managed context and the compositor's unmanaged one
/// (`LookSurface`): the renderer is one graph, and the two contexts are what
/// could make it two pictures.
///
/// ⚠️ **NOT THROUGH `MediaEdits.applied`.** That wraps this renderer in a crop
/// and a render of its own; a dial broken here would still be broken there, but
/// a test written there could not tell which half broke it.
@Suite
struct FrameLookRendererTests {
    private typealias RGB = PictureBitmap.RGB

    private func look(_ change: (inout FrameLook) -> Void) -> FrameLook {
        var look = FrameLook()
        change(&look)
        return look
    }

    private func dressed(_ image: CIImage, _ look: FrameLook, at time: Double = 0) -> CIImage {
        FrameLookRenderer.apply(look, to: image, time: time)
    }

    // MARK: - Identity

    @Test func aNeutralLookReturnsTheSameImage() {
        let picture = TestPicture.detailed()

        #expect(dressed(picture, .neutral) === picture, "a neutral look must not even build a graph")
        #expect(
            dressed(picture, FrameLook(effect: LookEffect(kind: .comic, intensity: 0))) === picture,
            "an effect at zero is no effect, so no graph either"
        )
        #expect(dressed(picture, look { $0.preset = .mono }) !== picture, "witness: a real look is a new image")
    }

    /// ⚠️ **A HAIR ABOVE ZERO IS STILL THE PICTURE, FOR EVERY EFFECT.** The
    /// intensity reaches the picture through the mix; without it a comic
    /// effect at 1% is the whole comic effect.
    @Test(arguments: LookSurface.allCases)
    func zeroIntensityIsTheSource(_ surface: LookSurface) {
        let picture = TestPicture.detailed()
        let source = surface.draw(picture)
        let faint = LookAdjustments.snap + 0.001

        for kind in LookEffectKind.allCases {
            let drawn = surface.draw(dressed(picture, FrameLook(effect: LookEffect(kind: kind, intensity: faint))))
            let worst = drawn.maxDistance(to: source)
            #expect(worst <= 3, "\(kind) at \(faint) moved a pixel by \(worst)")
        }
    }

    // MARK: - The dials

    @Test(arguments: LookSurface.allCases)
    func brightnessRaisesTheCentre(_ surface: LookSurface) {
        let grey = TestPicture.flat(100, 100, 100)
        let before = surface.draw(grey).centre
        let raised = surface.draw(dressed(grey, look { $0.adjustments.brightness = 0.6 })).centre
        let lowered = surface.draw(dressed(grey, look { $0.adjustments.brightness = -0.6 })).centre

        #expect(raised.r >= before.r + 20 && raised.g >= before.g + 20 && raised.b >= before.b + 20,
                "brightness +0.6 drew \(raised) from \(before)")
        #expect(lowered.r <= before.r - 20 && lowered.b <= before.b - 20,
                "brightness -0.6 drew \(lowered) from \(before)")
    }

    @Test(arguments: LookSurface.allCases)
    func contrastSpreadsAroundTheMiddle(_ surface: LookSurface) {
        let pair = TestPicture.make(width: 64, height: 32) { x, _ in x < 32 ? (70, 70, 70) : (185, 185, 185) }
        let before = surface.draw(pair)
        let after = surface.draw(dressed(pair, look { $0.adjustments.contrast = 0.8 }))

        #expect(after.rgb(10, 10).r <= before.rgb(10, 10).r - 15, "the dark side darkens: \(after.rgb(10, 10))")
        #expect(after.rgb(50, 10).r >= before.rgb(50, 10).r + 15, "the light side lightens: \(after.rgb(50, 10))")
    }

    @Test(arguments: LookSurface.allCases)
    func negativeSaturationDrains(_ surface: LookSurface) {
        let orange = TestPicture.flat(204, 77, 51)
        let before = surface.draw(orange).centre
        let drained = surface.draw(dressed(orange, look { $0.adjustments.saturation = -1 })).centre
        let vivid = surface.draw(dressed(orange, look { $0.adjustments.saturation = 0.8 })).centre

        #expect(before.r - before.b >= 100, "guard: the source is far from grey, \(before)")
        #expect(drained.distance(to: RGB(r: drained.g, g: drained.g, b: drained.g)) <= 3,
                "saturation -1 leaves grey: \(drained)")
        #expect(vivid.r - vivid.b > before.r - before.b + 20, "and +0.8 spreads the channels: \(vivid)")
    }

    /// ⚠️ **THE DIRECTION IS THE TEST'S TO SAY, NOT THE FILTER'S NAMES.**
    /// `CITemperatureAndTint` warms a picture when told its neutral is HOTTER
    /// than the target, which reads backwards. Checked at two strengths, so a
    /// dial that merely switches a fixed tint on passes neither.
    @Test(arguments: LookSurface.allCases)
    func warmthRaisesRedAndLowersBlue(_ surface: LookSurface) {
        let grey = TestPicture.flat(128, 128, 128)
        let before = surface.draw(grey).centre
        let mild = surface.draw(dressed(grey, look { $0.adjustments.warmth = 0.4 })).centre
        let full = surface.draw(dressed(grey, look { $0.adjustments.warmth = 1 })).centre
        let cool = surface.draw(dressed(grey, look { $0.adjustments.warmth = -1 })).centre

        #expect(mild.r > before.r + 2 && mild.b < before.b - 6, "warmth 0.4 drew \(mild) from \(before)")
        #expect(full.r > mild.r + 2 && full.b < mild.b - 6, "warmth 1 warms more than 0.4: \(full) vs \(mild)")
        #expect(cool.b > before.b + 12 && cool.r < before.r - 6, "warmth -1 cools: \(cool)")
    }

    /// Dark and light patches side by side: each dial moves its own patch
    /// much more than the other one — in both directions.
    @Test(arguments: LookSurface.allCases)
    func highlightsAndShadowsMoveTheirRange(_ surface: LookSurface) {
        let patches = TestPicture.make(width: 64, height: 32) { x, _ in x < 32 ? (38, 38, 38) : (217, 217, 217) }
        let before = surface.draw(patches)
        func moves(_ change: (inout FrameLook) -> Void) -> (dark: Int, light: Int) {
            let after = surface.draw(dressed(patches, look(change)))
            return (after.rgb(10, 10).g - before.rgb(10, 10).g, after.rgb(50, 10).g - before.rgb(50, 10).g)
        }

        let lifted = moves { $0.adjustments.shadows = 1 }
        let crushed = moves { $0.adjustments.shadows = -1 }
        let brightened = moves { $0.adjustments.highlights = 1 }
        let recovered = moves { $0.adjustments.highlights = -1 }

        #expect(lifted.dark >= 18 && abs(lifted.light) <= 8, "shadows +1 moved dark \(lifted.dark), light \(lifted.light)")
        #expect(crushed.dark <= -18 && abs(crushed.light) <= 8, "shadows -1 moved dark \(crushed.dark), light \(crushed.light)")
        #expect(brightened.light >= 18 && abs(brightened.dark) <= 8,
                "highlights +1 moved light \(brightened.light), dark \(brightened.dark)")
        #expect(recovered.light <= -18 && abs(recovered.dark) <= 8,
                "highlights -1 moved light \(recovered.light), dark \(recovered.dark)")
    }

    @Test(arguments: LookSurface.allCases)
    func sharpnessSteepensAnEdge(_ surface: LookSurface) {
        let edge = TestPicture.make(width: 64, height: 32) { x, _ in x < 32 ? (77, 77, 77) : (179, 179, 179) }
        let before = surface.draw(edge)
        let after = surface.draw(dressed(edge, look { $0.adjustments.sharpness = 1 }))

        #expect(after.rgb(31, 16).g < before.rgb(31, 16).g - 4, "the dark side of the edge darkens: \(after.rgb(31, 16))")
        #expect(after.rgb(32, 16).g > before.rgb(32, 16).g + 4, "the light side lightens: \(after.rgb(32, 16))")
        #expect(after.rgb(0, 16).distance(to: before.rgb(0, 16)) <= 2, "the picture's own edge is not an edge")
        #expect(after.rgb(10, 16).distance(to: before.rgb(10, 16)) <= 2, "and flat ground stays flat")
    }

    /// ⚠️ **AT TWO SIZES, BECAUSE A VIGNETTE IN PIXELS WOULD PASS AT ONE.** The
    /// same share of the frame darkens by the same amount at 160 wide and at
    /// 320 wide, or the preview and the export wear different vignettes.
    @Test(arguments: LookSurface.allCases)
    func vignetteDarkensCornersNotCentre(_ surface: LookSurface) {
        func samples(scale: Int) -> [RGB] {
            let width = 160 * scale
            let height = 90 * scale
            let flat = TestPicture.flat(204, 204, 204, width: width, height: height)
            let drawn = surface.draw(dressed(flat, look { $0.adjustments.vignette = 1 }))
            return [
                drawn.rgb(width / 2, height / 2),
                drawn.rgb(0, 0),
                drawn.rgb(0, height / 2),
                drawn.rgb(width / 4, height / 4),
                drawn.rgb(width - 1, height - 1)
            ]
        }
        let small = samples(scale: 1)
        let large = samples(scale: 2)

        #expect(small[0].distance(to: RGB(r: 204, g: 204, b: 204)) <= 2, "the centre is untouched: \(small[0])")
        #expect(small[1].g <= 120, "a corner darkens: \(small[1])")
        #expect(small[2].g < small[3].g && small[3].g < small[0].g, "darker towards the edge: \(small)")
        for (index, pair) in zip(small, large).enumerated() {
            #expect(pair.0.distance(to: pair.1) <= 6, "sample \(index) at 1x \(pair.0) and 2x \(pair.1)")
        }
    }

    /// ⚠️ **GRAIN THAT STOOD STILL WOULD BE DIRT ON THE LENS.** Two frames a
    /// fraction of a second apart must wear different grain; neither may
    /// brighten or darken the picture.
    @Test(arguments: LookSurface.allCases)
    func grainVariesWithTimeKeepsTheMean(_ surface: LookSurface) {
        let grey = TestPicture.flat(128, 128, 128, width: 96, height: 96)
        let grainy = look { $0.adjustments.grain = 1 }
        let first = surface.draw(dressed(grey, grainy, at: 0))
        let next = surface.draw(dressed(grey, grainy, at: 1.0 / 30))
        let later = surface.draw(dressed(grey, grainy, at: 2.5))

        #expect(first.deviation() >= 6, "the grain is visible: \(first.deviation())")
        #expect(next.shareChanged(from: first, by: 4) >= 0.5, "the next frame wears other grain")
        #expect(later.shareChanged(from: first, by: 4) >= 0.5, "and so does a later one")
        for (name, frame) in [("first", first), ("next", next), ("later", later)] {
            #expect(abs(frame.mean() - 128) <= 3, "\(name) frame's mean moved to \(frame.mean())")
        }
    }

    // MARK: - The order

    /// Warmth, then a monochrome preset: the preset has the last word, so the
    /// picture is grey. The other way round would leave it tinted.
    @Test(arguments: LookSurface.allCases)
    func presetOrderIsAdjustmentsThenPreset(_ surface: LookSurface) {
        let grey = TestPicture.flat(128, 128, 128)
        let warmed = surface.draw(dressed(grey, look { $0.adjustments.warmth = 1 })).centre
        let both = surface.draw(dressed(grey, look {
            $0.adjustments.warmth = 1
            $0.preset = .mono
        })).centre

        #expect(warmed.r - warmed.b >= 20, "witness: warmth alone tints the picture, \(warmed)")
        #expect(abs(both.r - both.b) <= 3, "the preset came last and left grey: \(both)")
    }

    // MARK: - The effects

    @Test(arguments: LookSurface.allCases, LookEffectKind.allCases)
    func eachEffectChangesPixels(_ surface: LookSurface, _ kind: LookEffectKind) {
        // Large enough that every size taken from the picture is several pixels.
        let picture = TestPicture.detailed(width: 320, height: 240)
        let source = surface.draw(picture)
        let drawn = surface.draw(dressed(picture, FrameLook(effect: LookEffect(kind: kind, intensity: 1))))

        #expect(drawn.meanDistance(to: source) >= 4, "\(kind) moved pixels by \(drawn.meanDistance(to: source)) on average")
    }

    /// A white bar on black: the split pushes red out past the bar's RIGHT
    /// edge and blue past its LEFT edge.
    @Test(arguments: LookSurface.allCases)
    func rgbSplitShiftsRedAtAnEdge(_ surface: LookSurface) {
        let bar = TestPicture.make(width: 400, height: 40) { x, _ in (160..<240).contains(x) ? (255, 255, 255) : (0, 0, 0) }
        let drawn = surface.draw(dressed(bar, FrameLook(effect: LookEffect(kind: .rgbSplit, intensity: 1))))
        // 1.2% of 400 is 4.8 pixels.
        let right = drawn.rgb(242, 20)
        let left = drawn.rgb(157, 20)
        let middle = drawn.rgb(200, 20)

        #expect(right.r >= 200 && right.b <= 20 && right.g <= 20, "red spills right: \(right)")
        #expect(left.b >= 200 && left.r <= 20 && left.g <= 20, "blue spills left: \(left)")
        #expect(middle.distance(to: RGB(r: 255, g: 255, b: 255)) <= 3, "the bar stays white: \(middle)")
        #expect(drawn.rgb(100, 20).distance(to: RGB(r: 0, g: 0, b: 0)) <= 3, "and the ground black")
    }

    /// ⚠️ **ON BOTH PATHS.** A radius of 4.5 is drawn at full size; 12 is
    /// drawn at a quarter and scaled back (`blurDownsamplesAbove`).
    @Test(arguments: LookSurface.allCases, [0.375, 1.0])
    func blurSoftensAnEdge(_ surface: LookSurface, _ intensity: Double) {
        // 3% of the short side at full intensity: 12 pixels, and 4.5 at 0.375.
        let edge = TestPicture.make(width: 600, height: 400) { x, _ in x < 300 ? (0, 0, 0) : (255, 255, 255) }
        let drawn = surface.draw(dressed(edge, FrameLook(effect: LookEffect(kind: .blur, intensity: intensity))))
        let radius = intensity * 0.03 * 400

        let inside = drawn.rgb(300 + Int(radius / 2), 200).g
        #expect(inside < 250 && inside > 128, "just inside the white, the blur shows: \(inside) at radius \(radius)")
        for x in [0, 50, 599, 550] {
            let far = drawn.rgb(x, 200)
            let expected = x < 300 ? 0 : 255
            #expect(abs(far.g - expected) <= 2, "far from the edge, at x=\(x), nothing moves: \(far)")
        }
        #expect(drawn.rgb(300, 0).g == drawn.rgb(300, 200).g, "the picture's own top and bottom edges are not darkened")
    }

    /// The cheap path draws what a full-size blur draws.
    ///
    /// ⚠️ **ON THE VIDEO CONTEXT ONLY.** Under the photo context the renderer
    /// blurs encoded values (`perceptual`) while a bare `CIGaussianBlur` blurs
    /// linear light, and across a black-to-white edge those differ by tens of
    /// units whatever the path. The compositor's context converts nothing, so
    /// the two blurs there differ only by the path.
    @Test func aWideBlurMatchesAFullSizeOne() {
        let surface = LookSurface.video
        let edge = TestPicture.make(width: 600, height: 400) { x, y in
            (x < 300 ? 0 : 255, y < 200 ? 40 : 220, (x / 50) % 2 == 0 ? 30 : 200)
        }
        let cheap = surface.draw(dressed(edge, FrameLook(effect: LookEffect(kind: .blur, intensity: 1))))
        let full = CIFilter.gaussianBlur()
        full.inputImage = edge.clampedToExtent()
        full.radius = 12
        let reference = surface.draw(full.outputImage!.cropped(to: edge.extent))

        #expect(12 > FrameLookRenderer.blurDownsamplesAbove, "guard: this radius takes the cheap path")
        #expect(cheap.maxDistance(to: reference) <= 4, "the quarter-size blur strays by \(cheap.maxDistance(to: reference))")
    }

    /// ⚠️ **THE PATH IS A COST, SO THE COST IS WHAT IS READ.** Core Image
    /// counts the pixels a render touched. Measured on a 1280×720 frame: a
    /// full-size `CIGaussianBlur` of 21.6 pixels touched 3.22 million, the
    /// quarter-size path 1.99 million — so the look's wide blur must touch
    /// fewer than the same blur drawn whole, which is only true while it takes
    /// the cheap path.
    ///
    /// ⚠️ **LIKE AGAINST LIKE, ON A PICTURE NO OTHER RENDER HAS DRAWN.** The
    /// reference goes through the same full-strength mix the look ends with, so
    /// neither side pays a pass the other skips — an earlier version compared
    /// against a narrower blur at a partial strength, whose mix pass outweighed
    /// the saving, and it stayed green with the cheap path deleted. And Core
    /// Image answers a graph it has already rendered from a cache, counting only
    /// the output's 921,600 pixels, so the checkerboard's colour is new on every
    /// run.
    @Test func aWideBlurCostsLessThanAFullSizeOne() throws {
        let checker = CIFilter.checkerboardGenerator()
        checker.width = 7
        checker.color0 = CIColor(red: .random(in: 0...1), green: .random(in: 0...1), blue: 0.5)
        checker.color1 = CIColor(red: 0, green: 0, blue: 0)
        let frame = CGRect(x: 0, y: 0, width: 1280, height: 720)
        let picture = try #require(checker.outputImage).cropped(to: frame)
        let radius = 0.03 * 720.0

        let whole = CIFilter.gaussianBlur()
        whole.inputImage = picture.clampedToExtent()
        whole.radius = Float(radius)
        let mix = CIFilter.mix()
        mix.inputImage = try #require(whole.outputImage).cropped(to: frame)
        mix.backgroundImage = picture
        mix.amount = 1
        let fullSize = try #require(mix.outputImage)
        let look = dressed(picture, FrameLook(effect: LookEffect(kind: .blur, intensity: 1)))

        func work(_ image: CIImage) throws -> Int {
            var bytes = [UInt8](repeating: 0, count: 4 * 1280 * 720)
            return try bytes.withUnsafeMutableBytes { buffer in
                let destination = CIRenderDestination(
                    bitmapData: buffer.baseAddress!, width: 1280, height: 720, bytesPerRow: 4 * 1280, format: .RGBA8
                )
                return try VideoCompositor.context
                    .startTask(toRender: image, from: frame, to: destination, at: .zero)
                    .waitUntilCompleted()
                    .pixelsProcessed
            }
        }

        #expect(radius > FrameLookRenderer.blurDownsamplesAbove, "guard: this radius takes the cheap path")
        let cheap = try work(look)
        let full = try work(fullSize)
        #expect(full > 921_600, "guard: the full-size blur was really drawn, not served from a cache (\(full))")
        #expect(cheap < full, "the look's 21.6-pixel blur touched \(cheap) pixels, drawn whole it touches \(full)")
    }

    /// Horizontal scanlines: alternate rows differ, averaged across the width
    /// so the tape's noise cancels out.
    @Test(arguments: LookSurface.allCases)
    func vhsDrawsHorizontalLines(_ surface: LookSurface) {
        let grey = TestPicture.flat(153, 153, 153, width: 240, height: 90)
        let drawn = surface.draw(dressed(grey, FrameLook(effect: LookEffect(kind: .vhs, intensity: 1))))
        func rowMean(_ y: Int) -> Double {
            Double((0..<drawn.width).map { drawn.rgb($0, y).g }.reduce(0, +)) / Double(drawn.width)
        }
        func columnMean(_ x: Int) -> Double {
            Double((0..<drawn.height).map { drawn.rgb(x, $0).g }.reduce(0, +)) / Double(drawn.height)
        }
        let rowSteps = (10..<80).map { abs(rowMean($0) - rowMean($0 + 1)) }
        let columnSteps = (10..<200).map { abs(columnMean($0) - columnMean($0 + 1)) }
        let rowStep = rowSteps.reduce(0, +) / Double(rowSteps.count)
        let columnStep = columnSteps.reduce(0, +) / Double(columnSteps.count)

        #expect(rowStep >= 10, "neighbouring rows differ by \(rowStep) on average")
        #expect(columnStep * 4 < rowStep, "neighbouring columns much less: \(columnStep) against \(rowStep)")
    }

    // MARK: - Geometry

    /// ⚠️ **EVERY STAGE, ALONE AND ALL AT ONCE, AT AN EXTENT OFF THE ORIGIN.**
    /// Generators are infinite and neighbourhood filters draw past the edge; a
    /// stage that forgot its crop hands the next one a bigger picture.
    @Test func everyStageKeepsTheExtent() {
        let picture = TestPicture.detailed().transformed(by: CGAffineTransform(translationX: 10, y: 20))

        #expect(picture.extent == CGRect(x: 10, y: 20, width: 96, height: 64), "guard: the extent is off the origin")
        for (name, look) in Self.everyStage {
            let extent = dressed(picture, look, at: 1.3).extent
            #expect(extent == picture.extent, "\(name) came back \(extent)")
        }
    }

    /// ⚠️ **AN OPAQUE PICTURE STAYS OPAQUE, READ IN FLOATS.** A stage that let
    /// the alpha run past one looks right in an 8-bit render — which clamps it
    /// — and turns the NEXT blend black: the RGB split once added three opaque
    /// channels into an alpha of 3, and the tape's grain came out black.
    @Test(arguments: LookSurface.allCases)
    func everyStageLeavesAnOpaquePictureOpaque(_ surface: LookSurface) {
        let picture = TestPicture.detailed()
        for (name, look) in Self.everyStage {
            let worst = surface.alphas(of: dressed(picture, look, at: 0.3)).map { abs($0 - 1) }.max() ?? 1
            #expect(worst <= 0.002, "\(name) left an alpha \(worst) away from one")
        }
    }

    /// Each stage alone, then all of them at once.
    private static var everyStage: [(String, FrameLook)] {
        var looks: [(String, FrameLook)] = []
        for key in LookAdjustments.Key.allCases {
            var look = FrameLook()
            look.adjustments[key] = 0.7
            looks.append(("\(key)", look))
        }
        for preset in LookPreset.allCases where preset != .original {
            looks.append(("\(preset)", FrameLook(preset: preset)))
        }
        for kind in LookEffectKind.allCases {
            looks.append(("\(kind)", FrameLook(effect: LookEffect(kind: kind, intensity: 0.8))))
        }
        var everything = FrameLook(preset: .instant, effect: LookEffect(kind: .rgbSplit, intensity: 1))
        for key in LookAdjustments.Key.allCases { everything.adjustments[key] = 0.5 }
        looks.append(("everything", everything))
        return looks
    }

    // MARK: - Parity

    /// ⚠️ **THE WHOLE LOOK, ON BOTH CONTEXTS, IS ONE PICTURE.** The photo
    /// context filters linear light and the compositor's filters encoded values;
    /// without `perceptual` the same dials drew up to 102 apart.
    @Test func aLookDrawsTheSameOnBothSurfaces() {
        let picture = TestPicture.detailed()
        var everything = FrameLook(preset: .chrome, effect: LookEffect(kind: .posterize, intensity: 0.7))
        everything.adjustments.brightness = 0.3
        everything.adjustments.contrast = 0.4
        everything.adjustments.saturation = -0.3
        everything.adjustments.warmth = 0.5
        everything.adjustments.shadows = 0.5
        everything.adjustments.highlights = -0.4
        everything.adjustments.sharpness = 0.5
        everything.adjustments.vignette = 0.6
        everything.adjustments.grain = 0.5
        let graph = dressed(picture, everything, at: 0.7)

        let photo = LookSurface.photo.draw(graph)
        let video = LookSurface.video.draw(graph)
        #expect(photo.maxDistance(to: video) <= 4, "the two contexts drew \(photo.maxDistance(to: video)) apart")
        #expect(photo.meanDistance(to: LookSurface.photo.draw(picture)) >= 10, "witness: the look changed the picture")
    }

    /// Each effect, one at a time. ⚠️ Comic draws hard thresholds, where a
    /// rounding either side flips a pixel from ink to paper, so it is held to
    /// its mean.
    @Test(arguments: LookEffectKind.allCases)
    func eachEffectDrawsTheSameOnBothSurfaces(_ kind: LookEffectKind) {
        let picture = TestPicture.detailed()
        let graph = dressed(picture, FrameLook(effect: LookEffect(kind: kind, intensity: 0.8)), at: 0.4)
        let photo = LookSurface.photo.draw(graph)
        let video = LookSurface.video.draw(graph)

        if kind == .comic {
            #expect(photo.meanDistance(to: video) <= 2, "comic drew \(photo.meanDistance(to: video)) apart on average")
        } else {
            #expect(photo.maxDistance(to: video) <= 3, "\(kind) drew \(photo.maxDistance(to: video)) apart")
        }
    }
}
