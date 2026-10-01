import Testing
import UIKit
@testable import DesignSystem

/// The banner run-out both picture-led headers share — see `HeroBannerFade`.
@MainActor
struct HeroBannerFadeTests {
    private let geometry = HeroBannerFade.geometry(identityTop: 300, foot: 540)

    /// One container, from just above the identity to the banner's foot,
    /// for the blur and the page's tone alike.
    @Test func theGeometryHangsOffTheIdentityAndTheFoot() {
        #expect(geometry.blurStart == 300 - HeroBannerFade.blurLead)
        #expect(HeroBannerFade.blurLead <= 12)
        #expect(geometry.blurFull == 540)
        #expect(geometry.rampStart == geometry.blurStart)
        #expect(geometry.rampEnd == 540)
        #expect(geometry.offset(by: -100).blurStart == geometry.blurStart - 100)
    }

    /// The levels hand over without a gap or an overlap — at any height at
    /// most two neighbours blend — from the blur's start to its full, and
    /// the climb is next to nothing first: the faintest level alone (sigma
    /// 1.5, blended in) takes over a quarter of the container, the
    /// strongest under a quarter.
    @Test func theLevelsTileTheClimb() throws {
        let spans = HeroBannerFade.levelSpans(geometry)
        try #require(spans.count == HeroBannerFade.blurSigmas.count)
        #expect(spans[0].start == geometry.blurStart)
        #expect(abs(spans[spans.count - 1].full - geometry.blurFull) < 0.001)
        for (lower, upper) in zip(spans, spans.dropFirst()) {
            #expect(abs(upper.start - lower.full) < 0.001)
            #expect(upper.full > upper.start)
        }
        let lead = geometry.blurFull - geometry.blurStart
        #expect(spans[0].full - spans[0].start > lead * 0.25)
        #expect(spans[spans.count - 1].full - spans[spans.count - 1].start < lead * 0.25)
        // Half way down, the blur is still under an eighth of its strongest:
        // the third level (sigma 7) is not whole before the middle.
        #expect(spans[2].full >= geometry.blurStart + lead * 0.5 - 0.001)
    }

    /// A profile's BAND climbs the ladder of levels, not the sigma (user, 1
    /// October 2026: "far too strong"): a breath of blur at the container's
    /// top — under 2% of the strongest a quarter of the way down, under 10%
    /// half way — rising faster and faster (convex), whole at the foot.
    @Test func aBandsBlurIsWeakAtItsStartAndConvex() throws {
        var band = geometry
        band.blurCurve = .ladder
        let lead = band.blurFull - band.blurStart
        let strongest = try #require(HeroBannerFade.blurSigmas.last)
        func sigma(_ t: CGFloat) -> CGFloat { HeroBannerFade.sigma(at: band.blurStart + lead * t, geometry: band) }
        #expect(sigma(0) == 0)
        #expect(sigma(0.25) <= strongest * 0.02, "\(sigma(0.25))")
        #expect(sigma(0.5) <= strongest * 0.1, "\(sigma(0.5))")
        #expect(abs(sigma(1) - strongest) < 0.001)
        // Softer than the sigma curve everywhere above the foot.
        for step in 1..<20 {
            let t = CGFloat(step) / 20
            let plain = HeroBannerFade.sigma(at: geometry.blurStart + lead * t, geometry: geometry)
            #expect(sigma(t) <= plain + 0.001, "t \(t): \(sigma(t)) vs \(plain)")
        }
        // Convex: the climb only ever steepens.
        let samples = stride(from: CGFloat(0), through: 1, by: 0.01).map(sigma)
        for index in 2..<samples.count {
            let second = samples[index] - 2 * samples[index - 1] + samples[index - 2]
            #expect(second >= -0.001, "at \(index): \(second)")
        }
        // Still the levels, tiling the climb without a gap.
        let spans = HeroBannerFade.levelSpans(band)
        try #require(spans.count == HeroBannerFade.blurSigmas.count)
        #expect(spans[0].start == band.blurStart)
        #expect(abs(spans[spans.count - 1].full - band.blurFull) < 0.001)
        for (lower, upper) in zip(spans, spans.dropFirst()) {
            #expect(abs(upper.start - lower.full) < 0.001)
        }
    }

    /// Posters and places keep the sigma curve: their spans are exactly
    /// `t^blurCurveExponent` of the strongest sigma, as before.
    @Test func postersAndPlacesKeepTheSigmaCurve() throws {
        let shouldered = HeroBannerFade.shoulderedGeometry(identityTop: 300, foot: 540)
        #expect(geometry.blurCurve == .sigma)
        #expect(shouldered.blurCurve == .sigma)
        let strongest = try #require(HeroBannerFade.blurSigmas.last)
        for fade in [geometry, shouldered] {
            let lead = fade.blurFull - fade.blurStart
            func depth(_ sigma: CGFloat) -> CGFloat {
                fade.blurStart + lead * pow(sigma / strongest, 1 / HeroBannerFade.blurCurveExponent)
            }
            let expected = zip([0] + HeroBannerFade.blurSigmas.dropLast(), HeroBannerFade.blurSigmas)
                .map { (depth($0), depth($1)) }
            let spans = HeroBannerFade.levelSpans(fade)
            #expect(spans.map(\.start) == expected.map(\.0))
            #expect(spans.map(\.full) == expected.map(\.1))
        }
    }

    /// The page's tone over the whole container — the picture's fade into
    /// the page, under the blur — clear at its top, whole at the foot, and
    /// eased in: a few percent a third of the way down, where the type
    /// stands, most of it in the last third.
    @Test func theRampFadesThePictureOverTheWholeContainer() throws {
        let height: CGFloat = 600
        let stops = HeroBannerFade.rampStops(height: height, geometry: geometry)
        try #require(stops.count >= 8)
        #expect(stops.first?.1 == 0)
        #expect(stops.last?.1 == 1)
        for (a, b) in zip(stops, stops.dropFirst()) {
            #expect(b.0 >= a.0)
            #expect(b.1 >= a.1)
        }
        let clearUntil = stops.last { $0.1 == 0 }?.0 ?? 0
        let wholeFrom = stops.first { $0.1 == 1 }?.0 ?? 1
        #expect(abs(clearUntil * height - geometry.rampStart) < 0.001)
        #expect(abs(wholeFrom * height - geometry.rampEnd) < 0.001)
        let length = geometry.rampEnd - geometry.rampStart
        func alpha(atFraction t: CGFloat) -> CGFloat {
            HeroBannerFade.rampAlpha(at: geometry.rampStart + length * t, geometry: geometry)
        }
        #expect(alpha(atFraction: 1.0 / 3) < 0.05)
        #expect(alpha(atFraction: 2.0 / 3) < 0.35)
        #expect(alpha(atFraction: 0.9) > 0.6)
        #expect(HeroBannerFade.rampAlpha(at: geometry.rampStart - 50, geometry: geometry) == 0)
        #expect(HeroBannerFade.rampAlpha(at: geometry.rampEnd + 50, geometry: geometry) == 1)
        // The stops draw the same curve the ground is read with.
        for stop in stops.dropFirst().dropLast() {
            #expect(abs(HeroBannerFade.rampAlpha(at: stop.0 * height, geometry: geometry) - stop.1) < 0.001)
        }
    }

    /// A shouldered ramp — type on the picture from the container's top: the
    /// blur exactly as the plain one, the page's tone eased in over the rise
    /// above the container and already `shoulderAlpha` at its top, then on
    /// to whole at the foot, without a step anywhere.
    @Test func aShoulderedRampPutsHalfThePageUnderTheTypeAndLeavesTheBlur() throws {
        let plain = HeroBannerFade.geometry(identityTop: 300, foot: 540)
        let shouldered = HeroBannerFade.shoulderedGeometry(identityTop: 300, foot: 540)
        #expect(shouldered.blurStart == plain.blurStart)
        #expect(shouldered.blurFull == plain.blurFull)
        #expect(HeroBannerFade.levelSpans(shouldered).map(\.full) == HeroBannerFade.levelSpans(plain).map(\.full))
        let shoulder = try #require(shouldered.rampShoulder)
        #expect(shoulder == plain.blurStart)
        #expect(shouldered.rampStart == shoulder - HeroBannerFade.shoulderRise)
        func alpha(_ y: CGFloat) -> CGFloat { HeroBannerFade.rampAlpha(at: y, geometry: shouldered) }
        #expect(alpha(shouldered.rampStart - 1) == 0)
        #expect(abs(alpha(shoulder) - HeroBannerFade.shoulderAlpha) < 0.001)
        #expect(alpha(shouldered.rampEnd) == 1)
        // Monotonic, and no jump bigger than the curve allows in a point.
        var previous: CGFloat = 0
        for y in stride(from: shouldered.rampStart - 4, through: shouldered.rampEnd + 4, by: 1) {
            let value = alpha(y)
            #expect(value >= previous - 0.0001)
            #expect(value - previous < 0.03)
            previous = value
        }
        // The stops draw the same curve.
        let height: CGFloat = 600
        for stop in HeroBannerFade.rampStops(height: height, geometry: shouldered).dropFirst().dropLast() {
            #expect(abs(alpha(stop.0 * height) - stop.1) < 0.001)
        }
    }

    /// The ground the type's ink is picked over is what is drawn there: the
    /// blurred picture with the page's tone over it at each row's height —
    /// nothing of the page above the container, nearly all of it at the foot.
    @Test func theGroundIncludesThePagesTone() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let black = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 60), format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 60))
        }
        let view = HeroBannerPictureView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        view.pageTone = .white
        view.image = black
        view.fade = HeroBannerFade.geometry(identityTop: 300, foot: 600)
        view.layoutIfNeeded()
        func mean(_ rect: CGRect) throws -> Float {
            let pixels = try #require(view.groundPixels(behind: rect))
            try #require(!pixels.isEmpty)
            return pixels.map { ($0.x + $0.y + $0.z) / 3 }.reduce(0, +) / Float(pixels.count)
        }
        #expect(try mean(CGRect(x: 100, y: 200, width: 50, height: 10)) < 0.02)
        #expect(try mean(CGRect(x: 100, y: 590, width: 50, height: 10)) > 0.85)
    }

    /// A bake yields one level per sigma, each blurrier than the last: over
    /// hard stripes, the spread of a row's pixels shrinks level by level.
    @Test func eachLevelIsBlurrierThanTheLast() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let stripes = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 60), format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 60))
            UIColor.white.setFill()
            for x in stride(from: 0, to: 120, by: 8) {
                context.fill(CGRect(x: x, y: 0, width: 4, height: 60))
            }
        }
        let levels = try #require(HeroBannerFade.bakeLevels(of: stripes, displayScale: 2))
        #expect(levels.count == HeroBannerFade.blurSigmas.count)
        func spread(_ image: UIImage) throws -> Int {
            let cgImage = try #require(image.cgImage)
            let width = cgImage.width
            var pixels = [UInt8](repeating: 0, count: width * 4)
            let context = try #require(CGContext(
                data: &pixels, width: width, height: 1, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            // One row from the middle.
            context.draw(cgImage, in: CGRect(x: 0, y: -CGFloat(cgImage.height / 2), width: CGFloat(width), height: CGFloat(cgImage.height)))
            // The middle half only: the bake extends the picture's edge
            // columns, which biases the first and last sigma or two.
            let reds = stride(from: width / 4 * 4, to: width * 3 / 4 * 4, by: 4).map { Int(pixels[$0]) }
            return (reds.max() ?? 0) - (reds.min() ?? 0)
        }
        let spreads = try levels.map(spread)
        for (fainter, stronger) in zip(spreads, spreads.dropFirst()) {
            // Within a few levels of 8-bit rounding once both are flat.
            #expect(stronger <= fainter + 4, "\(spreads)")
        }
        #expect(spreads[0] > spreads[spreads.count - 1], "\(spreads)")
        let previous = spreads[spreads.count - 1]
        // The strongest level has all but erased 8pt-period stripes shown at
        // 2x (16pt on screen) — sigma 13pt.
        #expect(previous < 40)
    }

    // MARK: - The blur as one image (`HeroBannerBlurRows`)

    /// A 10x100 level whose every pixel in row `r` is `value(r)` grey.
    private func level(_ value: (Int) -> UInt8) throws -> UIImage {
        let width = 10, height = 100
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                let index = (row * width + column) * 4
                bytes[index] = value(row); bytes[index + 1] = value(row); bytes[index + 2] = value(row)
            }
        }
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let context = try #require(CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: space, bitmapInfo: info
        ))
        let image = try #require(context.makeImage())
        return UIImage(cgImage: image)
    }

    /// The (grey, alpha) of `image`'s pixel in `row`, middle column.
    private func pixel(_ image: CGImage, row: Int) throws -> (grey: Int, alpha: Int) {
        let data = try #require(image.dataProvider?.data)
        let bytes = try #require(CFDataGetBytePtr(data))
        let index = row * image.bytesPerRow + image.width / 2 * 4
        return (Int(bytes[index + 2]), Int(bytes[index + 3]))
    }

    /// Row for row, the blur image is what the six masked layers drew: clear
    /// above the climb; over the first span the faintest level fading in
    /// (premultiplied, over the sharp picture drawn under it); below, two
    /// neighbours mixed at the row's weight; the strongest alone at the foot.
    @Test func theCompositeMixesNeighboursRowByRow() throws {
        let greys: [UInt8] = [20, 60, 100, 140, 180, 220]
        let levels = try greys.map { grey in try level { _ in grey } }
        let rows = try #require(HeroBannerBlurRows(levels: levels))
        let spans = (0..<6).map { index -> (start: CGFloat, full: CGFloat) in
            let start = CGFloat(20 + 10 * index)
            return (start, start + 10)
        }
        let image = try #require(rows.composite(rows: 100, from: 0, spans: spans, pictureTop: 0, rowPitch: 1))
        #expect(image.height == 100)
        let above = try pixel(image, row: 10)
        #expect(above.grey == 0 && above.alpha == 0)
        // Row 25's middle, 25.5, is 55% into the first span.
        let fadingIn = try pixel(image, row: 25)
        #expect(abs(fadingIn.alpha - 140) <= 1)
        #expect(abs(fadingIn.grey - 11) <= 1)
        // 55% from the first level to the second.
        let mixed = try pixel(image, row: 35)
        #expect(abs(mixed.grey - 42) <= 1)
        #expect(mixed.alpha == 255)
        let foot = try pixel(image, row: 90)
        #expect(foot.grey == 220 && foot.alpha == 255)
    }

    /// The parallax: a picture slid down reads each row from the picture's
    /// row now behind it — between two rows, the two mixed.
    @Test func theCompositeReadsWhereThePictureSlid() throws {
        let ramp = try level { UInt8($0) }
        let rows = try #require(HeroBannerBlurRows(levels: Array(repeating: ramp, count: 6)))
        let spans = (0..<6).map { index -> (start: CGFloat, full: CGFloat) in
            let start = CGFloat(10 * index)
            return (start, start + 10)
        }
        let still = try #require(rows.composite(rows: 100, from: 0, spans: spans, pictureTop: 0, rowPitch: 1))
        let stillPixel = try pixel(still, row: 80)
        #expect(stillPixel.grey == 80)
        let slid = try #require(rows.composite(rows: 100, from: 0, spans: spans, pictureTop: 5, rowPitch: 1))
        let slidPixel = try pixel(slid, row: 80)
        #expect(slidPixel.grey == 75)
        let halfway = try #require(rows.composite(rows: 100, from: 0, spans: spans, pictureTop: 5.5, rowPitch: 1))
        let halfwayPixel = try pixel(halfway, row: 80)
        #expect(abs(halfwayPixel.grey - 74) <= 1)
    }

    /// What makes the banner cheap to scroll: its whole tree draws nothing
    /// offscreen — no mask, no group, no shadow — before and after the
    /// picture slides, with every level showing. #331's six masked layers
    /// were six offscreen passes on every frame of a scroll.
    @Test func theBlurDrawsNothingOffscreen() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let stripes = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 60), format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 60))
            UIColor.white.setFill()
            for y in stride(from: 0, to: 60, by: 6) { context.fill(CGRect(x: 0, y: y, width: 40, height: 3)) }
        }
        let view = HeroBannerPictureView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        view.image = stripes
        view.fade = HeroBannerFade.geometry(identityTop: 300, foot: 600)
        view.layoutIfNeeded()
        #expect(view.debugVisibleLevels.count == HeroBannerFade.blurSigmas.count)
        #expect(HeroScrollFrameProbe.Census(of: view.layer).offscreen == 0)
        view.pictureShift = 30
        view.layoutIfNeeded()
        #expect(HeroScrollFrameProbe.Census(of: view.layer).offscreen == 0)
    }

    // MARK: - A pull-down (`stretch`)

    /// A banner stretched by a pull, frame after frame, only ZOOMS what it
    /// drew at rest: nothing composed, nothing baked, the ground under the
    /// type the same — and still the picture covers the whole stretched
    /// view, its blur's top line where it was, nothing drawn offscreen.
    @Test func aStretchZoomsWithoutRecomposingOrRebaking() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        // Portrait: the fill is height-limited, the case a stretch rescaled
        // (and re-baked past `rebakeTolerance`) before.
        let stripes = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 90), format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 60, height: 90))
            UIColor.white.setFill()
            for y in stride(from: 0, to: 90, by: 6) { context.fill(CGRect(x: 0, y: y, width: 60, height: 3)) }
        }
        let rest = CGRect(x: 0, y: 0, width: 400, height: 300)
        let view = HeroBannerPictureView(frame: rest)
        view.pictureOutset.top = 80
        view.image = stripes
        let fade = HeroBannerFade.geometry(identityTop: 200, foot: 300)
        view.fade = fade
        view.layoutIfNeeded()
        let composed = view.debugComposeCount
        let baked = view.debugBakeCount
        try #require(composed > 0 && baked > 0)
        let levels = view.debugVisibleLevels.map(\.full)
        let type = CGRect(x: 40, y: 200, width: 200, height: 30)
        let ground = try #require(view.groundPixels(behind: type))
        for pull in stride(from: CGFloat(4), through: 200, by: 4) {
            // The view grows upward, as a banner pinned to the viewport's
            // top does under a pull; its foot holds.
            view.frame = CGRect(x: 0, y: -pull, width: 400, height: 300 + pull)
            view.stretch = pull
            view.layoutIfNeeded()
            #expect(view.debugComposeCount == composed, "pull \(pull)")
            #expect(view.debugBakeCount == baked, "pull \(pull)")
            let cover = view.debugPictureCover
            #expect(cover.minY <= 0.5, "pull \(pull): \(cover)")
            #expect(cover.maxY >= view.bounds.height - 0.5, "pull \(pull): \(cover)")
            #expect(cover.minX <= 0.5 && cover.maxX >= 399.5, "pull \(pull): \(cover)")
        }
        #expect(HeroScrollFrameProbe.Census(of: view.layer).offscreen == 0)
        // At rest coordinates nothing moved: the levels, the ground.
        #expect(view.debugVisibleLevels.map(\.full) == levels)
        #expect(try #require(view.groundPixels(behind: type)) == ground)
        // And back at rest, nothing is left zoomed — nor recomposed.
        view.frame = rest
        view.stretch = 0
        view.layoutIfNeeded()
        #expect(view.debugPictureCover.minY == -80)
        #expect(view.debugComposeCount == composed)
    }

    /// The ramp under a pull: drawn from the picture's resting top down,
    /// the same stops — only moved, never redrawn.
    @Test func aStretchMovesTheRampWithoutRedrawingIt() {
        let ramp = HeroBannerRampView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        ramp.fade = HeroBannerFade.geometry(identityTop: 200, foot: 300)
        ramp.layoutIfNeeded()
        let locations = ramp.debugLocations
        let alphas = ramp.debugAlphas
        ramp.frame = CGRect(x: 0, y: -120, width: 400, height: 420)
        ramp.stretch = 120
        ramp.layoutIfNeeded()
        #expect(ramp.debugLocations == locations)
        #expect(ramp.debugAlphas == alphas)
        #expect(ramp.debugRampFrame == CGRect(x: 0, y: 120, width: 400, height: 300))
    }

    // MARK: - The ink the ground picks (`HeroInk.tone`)

    private func ground(_ grey: Float, count: Int = 50) -> [SIMD3<Float>] {
        Array(repeating: SIMD3(grey, grey, grey), count: count)
    }

    /// Black on a light ground, white on a dark one, whatever was worn.
    @Test func theGroundPicksTheInk() {
        for current in [nil, HeroInk.Tone.light, .dark] {
            #expect(HeroInk.tone(forGround: ground(0.95), current: current) == .dark)
            #expect(HeroInk.tone(forGround: ground(0.1), current: current) == .light)
        }
        #expect(HeroInk.tone(forGround: [], current: nil) == HeroInk.defaultTone)
    }

    /// Around the crossover (sRGB ~0.46, luminance 0.18) both inks clear
    /// 4.5:1, and a block keeps the one it wears rather than flip on a
    /// re-read.
    @Test func aMidGroundKeepsTheInkItWears() {
        #expect(HeroInk.tone(forGround: ground(0.46), current: .light) == .light)
        #expect(HeroInk.tone(forGround: ground(0.46), current: .dark) == .dark)
    }

    /// Over a sharp, mixed ground — mostly a white shirt, some black hair —
    /// neither ink is legible everywhere, and the one that reads over most
    /// of it wins, whatever was worn (a poster's counters kept white over
    /// white at 1.51:1 before).
    @Test func aMixedGroundTakesTheInkThatReadsOverMostOfIt() {
        let mostlyLight = ground(0.95, count: 70) + ground(0.02, count: 30)
        #expect(HeroInk.tone(forGround: mostlyLight, current: .light) == .dark)
        let mostlyDark = ground(0.02, count: 70) + ground(0.95, count: 30)
        #expect(HeroInk.tone(forGround: mostlyDark, current: .dark) == .light)
    }

    /// Over ANY even ground, the ink picked clears AA — the promise that let
    /// the scrim go. Measured over the whole grey ramp.
    @Test func theInkPickedClearsAAOverAnyEvenGround() {
        for step in 0...100 {
            let grey = Float(step) / 100
            let tone = HeroInk.tone(forGround: ground(grey, count: 1), current: nil)
            var ink = (r: CGFloat(0), g: CGFloat(0), b: CGFloat(0), a: CGFloat(0))
            tone.secondary.getRed(&ink.r, green: &ink.g, blue: &ink.b, alpha: &ink.a)
            let back = CGFloat(grey)
            let front = ink.r * ink.a + back * (1 - ink.a)
            let ratio = HeroInk.contrast(
                HeroInk.luminance([front, front, front]), HeroInk.luminance([back, back, back])
            )
            #expect(ratio >= 4.5, "grey \(grey): \(tone) \(ratio)")
        }
    }
}
