import Testing
import UIKit
@testable import DesignSystem

/// The banner run-out both picture-led headers share — see `HeroBannerFade`.
@MainActor
struct HeroBannerFadeTests {
    private let geometry = HeroBannerFade.geometry(typeTop: 300, edge: 360)

    /// The blur's container from the lead above the type to the banner's
    /// foot (the ramp's end); the page's short ramp centred on the edge.
    @Test func theGeometryHangsOffTheTypeAndTheEdge() {
        #expect(geometry.blurFull == 360 + HeroBannerFade.rampLength / 2)
        #expect(geometry.blurStart == 300 - HeroBannerFade.blurLead)
        #expect(geometry.rampStart == 360 - HeroBannerFade.rampLength / 2)
        #expect(geometry.rampEnd == 360 + HeroBannerFade.rampLength / 2)
        #expect(geometry.offset(by: -100).blurStart == geometry.blurStart - 100)
    }

    /// The levels hand over without a gap or an overlap — at any height at
    /// most two neighbours blend — from the blur's start to its full, and
    /// the climb is gentle first: the faintest level takes a sixth of the
    /// lead, the strongest under a third.
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
        #expect(spans[0].full - spans[0].start > lead * 0.15)
        #expect(spans[spans.count - 1].full - spans[spans.count - 1].start < lead * 0.3)
    }

    /// Clear above the ramp, eased across it, whole below.
    @Test func theRampIsShortAndWholeBelowTheEdge() throws {
        let height: CGFloat = 400
        let stops = HeroBannerFade.rampStops(height: height, geometry: geometry)
        try #require(stops.count >= 3)
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
