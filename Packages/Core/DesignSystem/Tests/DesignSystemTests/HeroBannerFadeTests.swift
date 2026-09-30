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
