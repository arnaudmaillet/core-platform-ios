import CoreVideo
import Testing
import UIKit
@testable import PostGrid

/// The playing band of a fitted clip (`LiveMediaBackdrop`): the same look as
/// the still, a bounded rate, and a lifecycle that falls back to the still
/// everywhere it should.
///
/// No decoder here: the source is a fake that hands out a pixel buffer the
/// test made, and the frame token stands for "a new frame was displayed".
@MainActor
struct LiveMediaBackdropTests {
    // MARK: - The look

    /// ⚠️ THE HAND-OVER CLAIM. A clip's band starts as its blurred poster and
    /// becomes its blurred frames; if the two treatments differed, the moment
    /// playback starts would be a visible change of look. Same picture in,
    /// same band out — to within rounding.
    @Test func aFrameAndAStillOfTheSamePictureMakeTheSameBand() throws {
        let colour = UIColor(red: 0.8, green: 0.3, blue: 0.1, alpha: 1)
        let size = CGSize(width: 720, height: 900)
        let still = try #require(MediaBackdrop.blurred(Self.solid(colour, size)))
        let frame = try #require(Self.bgraBuffer(colour, size))
        let live = try #require(BackdropFrameReducer.shared.backdrop(from: frame))
        let stillPixels = try #require(still.cgImage)
        let livePixels = try #require(live.cgImage)
        #expect(stillPixels.width == livePixels.width && stillPixels.height == livePixels.height,
                "\(stillPixels.width)x\(stillPixels.height) vs \(livePixels.width)x\(livePixels.height)")
        let a = try #require(Self.averageColour(still))
        let b = try #require(Self.averageColour(live))
        #expect(abs(a.r - b.r) < 0.03 && abs(a.g - b.g) < 0.03 && abs(a.b - b.b) < 0.03,
                "still \(a) live \(b)")
    }

    /// What a decoder actually hands over is bi-planar YCbCr, not BGRA. A
    /// mid-grey frame comes out mid-grey and darkened — not black, not green
    /// (the colour a mis-read chroma plane gives).
    @Test func aDecodedYCbCrFrameReducesToItsColourDarkened() throws {
        let frame = try #require(Self.greyYCbCrBuffer(CGSize(width: 1080, height: 1350)))
        let band = try #require(BackdropFrameReducer.shared.backdrop(from: frame))
        let pixels = try #require(band.cgImage)
        #expect(max(pixels.width, pixels.height) == MediaBackdrop.reducedLongSide)
        let (r, g, b) = try #require(Self.averageColour(band))
        #expect(r > 0.3 && r < 0.5, "red \(r)")
        #expect(abs(r - g) < 0.05 && abs(g - b) < 0.05, "\(r) \(g) \(b)")
    }

    // MARK: - Rate

    @Test func aSampleWaitsForANewFrameTheIntervalAndTheLastSample() {
        let interval = 1 / LiveMediaBackdrop.samplesPerSecond
        #expect(LiveMediaBackdrop.shouldSample(now: 10, lastSample: 10 - interval, token: 2,
                                               lastToken: 1, isConverting: false))
        // The same frame again: a paused clip costs nothing.
        #expect(!LiveMediaBackdrop.shouldSample(now: 10, lastSample: 0, token: 1,
                                                lastToken: 1, isConverting: false))
        // Too soon: a 60 or 120 Hz display does not make it a 60 Hz band.
        #expect(!LiveMediaBackdrop.shouldSample(now: 10, lastSample: 10 - interval / 3, token: 2,
                                                lastToken: 1, isConverting: false))
        // One in flight at most.
        #expect(!LiveMediaBackdrop.shouldSample(now: 10, lastSample: 0, token: 2,
                                                lastToken: 1, isConverting: true))
    }

    /// Ticked at 60 Hz for a second with a new frame on every tick, the band
    /// is redrawn about a dozen times — never once per frame.
    @Test func aSecondOfSixtyHertzFramesIsADozenBands() async throws {
        let rig = try Rig()
        rig.band.setActive(true)
        for tick in 0..<60 {
            rig.source.token += 1
            rig.band.debugTick(now: 100 + Double(tick) / 60)
            // Let each sample land before the next tick, as a real one would.
            await rig.settle { !rig.band.debugIsConverting }
        }
        let drawn = rig.band.debugDeliveredCount
        #expect(drawn >= 10 && drawn <= 13, "\(drawn) bands")
        rig.band.setActive(false)
    }

    // MARK: - Lifecycle

    @Test func aPlayingClipReplacesTheStillWithItsFrames() async throws {
        let rig = try Rig()
        rig.band.setActive(true)
        #expect(rig.band.isRunning)
        rig.source.token = 1
        rig.band.debugTick(now: 1)
        await rig.settle { rig.band.isShowingLive }
        #expect(rig.band.isShowingLive)
        #expect(rig.target.image != nil && rig.target.image !== rig.still)
        rig.band.setActive(false)
    }

    /// A page that stops being watched keeps the frame it paused on — its
    /// picture is paused on that same frame — and stops sampling.
    @Test func leavingTheScreenStopsSamplingAndKeepsTheFrame() async throws {
        let rig = try Rig()
        rig.band.setActive(true)
        rig.source.token = 1
        rig.band.debugTick(now: 1)
        await rig.settle { rig.band.isShowingLive }
        let live = rig.target.image
        rig.band.setActive(false)
        #expect(!rig.band.isRunning)
        #expect(rig.target.image === live)
        // A still arriving meanwhile (a re-decided framing) is kept for later
        // and does not overwrite the frame on screen.
        rig.band.setStill(Self.solid(.blue, CGSize(width: 4, height: 4)))
        #expect(rig.target.image === live)
    }

    /// A sample still being made when its page leaves is dropped, not drawn.
    @Test func aSampleInFlightWhenThePageLeavesIsDropped() async throws {
        let rig = try Rig(slowReduce: true)
        rig.band.setActive(true)
        rig.source.token = 1
        rig.band.debugTick(now: 1)
        rig.band.setActive(false)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!rig.band.isShowingLive)
        #expect(rig.target.image === rig.still)
    }

    /// A recycled card, or a new post: the still, at once.
    @Test func returningToTheStillPutsThePosterBack() async throws {
        let rig = try Rig()
        rig.band.setActive(true)
        rig.source.token = 1
        rig.band.debugTick(now: 1)
        await rig.settle { rig.band.isShowingLive }
        rig.band.setActive(false)
        rig.band.returnToStill()
        #expect(!rig.band.isShowingLive)
        #expect(rig.target.image === rig.still)
    }

    /// The surface went back to its poster (a stopped player): so does the
    /// band.
    @Test func aSourceThatStopsDrawingFramesPutsTheStillBack() async throws {
        let rig = try Rig()
        rig.band.setActive(true)
        rig.source.token = 1
        rig.band.debugTick(now: 1)
        await rig.settle { rig.band.isShowingLive }
        rig.source.isShowingLiveFrames = false
        rig.band.debugTick(now: 2)
        #expect(!rig.band.isShowingLive)
        #expect(rig.target.image === rig.still)
        rig.band.setActive(false)
    }

    /// Reduce Motion or Low Power Mode: the band never starts…
    @Test func reducedMotionOrLowPowerKeepsTheStill() async throws {
        let rig = try Rig()
        rig.band.isSuppressedBySystem = { true }
        rig.band.setActive(true)
        #expect(!rig.band.isRunning)
        rig.source.token = 1
        rig.band.debugTick(now: 1)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!rig.band.isShowingLive)
        #expect(rig.target.image === rig.still)
    }

    /// …and a band already playing goes back to the still when either is
    /// switched on.
    @Test func switchingOnReducedMotionMidClipPutsTheStillBack() async throws {
        let rig = try Rig()
        var suppressed = false
        rig.band.isSuppressedBySystem = { suppressed }
        rig.band.setActive(true)
        rig.source.token = 1
        rig.band.debugTick(now: 1)
        await rig.settle { rig.band.isShowingLive }
        suppressed = true
        rig.band.debugSettingsChanged()
        #expect(!rig.band.isRunning)
        #expect(!rig.band.isShowingLive)
        #expect(rig.target.image === rig.still)
    }

    /// Nothing is sampled from a band nobody can see.
    @Test func aBandOutsideAWindowSamplesNothing() async throws {
        let rig = try Rig()
        rig.target.removeFromSuperview()
        rig.band.setActive(true)
        rig.source.token = 1
        rig.band.debugTick(now: 1)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!rig.band.isShowingLive)
        rig.band.setActive(false)
    }

    // MARK: - Rig

    @MainActor
    private final class FakeSource: LiveBackdropFrameSource {
        var token: CFTimeInterval = 0
        var buffer: CVPixelBuffer?
        var isShowingLiveFrames = true
        var liveFrameToken: CFTimeInterval { token }
        var liveFrameBuffer: CVPixelBuffer? { buffer }
    }

    @MainActor
    private struct Rig {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let target = UIImageView()
        let source = FakeSource()
        let still: UIImage
        let band: LiveMediaBackdrop

        init(slowReduce: Bool = false) throws {
            still = LiveMediaBackdropTests.solid(.darkGray, CGSize(width: 30, height: 40))
            window.isHidden = false
            target.frame = window.bounds
            window.addSubview(target)
            source.buffer = try #require(LiveMediaBackdropTests.bgraBuffer(.red, CGSize(width: 64, height: 80)))
            band = LiveMediaBackdrop(target: target)
            band.source = source
            band.isSuppressedBySystem = { false }
            band.usesDisplayLink = false
            if slowReduce {
                band.reduce = { buffer in
                    Thread.sleep(forTimeInterval: 0.1)
                    return BackdropFrameReducer.shared.backdrop(from: buffer)
                }
            }
            band.setStill(still)
        }

        func settle(until condition: () -> Bool) async {
            for _ in 0..<300 where !condition() {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    // MARK: - Pictures

    static func solid(_ colour: UIColor, _ size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            colour.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// A BGRA buffer of one colour, drawn through CoreGraphics in sRGB so it
    /// holds exactly what `solid` does.
    static func bgraBuffer(_ colour: UIColor, _ size: CGSize) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height),
                                  kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess,
              let buffer
        else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.setFillColor(colour.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey,
                              CGColorSpace(name: CGColorSpace.sRGB)!, .shouldPropagate)
        return buffer
    }

    /// A video-range 4:2:0 buffer of mid grey: luma 126, both chroma at the
    /// neutral 128 — what a decoder hands the renderer.
    static func greyYCbCrBuffer(_ size: CGSize) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height),
                                  kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                  attributes, &buffer) == kCVReturnSuccess,
              let buffer
        else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for (plane, value) in [(0, UInt8(126)), (1, UInt8(128))] {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { return nil }
            memset(base, Int32(value),
                   CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        return buffer
    }

    static func averageColour(_ image: UIImage) -> (r: Double, g: Double, b: Double)? {
        guard let cg = image.cgImage else { return nil }
        var data = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Double(data[0]) / 255, Double(data[1]) / 255, Double(data[2]) / 255)
    }
}
