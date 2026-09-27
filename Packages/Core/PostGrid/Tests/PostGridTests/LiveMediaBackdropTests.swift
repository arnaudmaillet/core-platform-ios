import CoreVideo
import MediaPlayback
import Testing
import UIKit
@testable import PostGrid

/// The playing band of a fitted clip (`LiveMediaBackdrop`): the same look as
/// the still, drawn with its own frame and never another's, and a lifecycle
/// that falls back to the still everywhere it should.
///
/// No decoder here: the test plays the renderer's part, handing over pixel
/// buffers it made (`prepare`) and saying when each goes on screen
/// (`present`).
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

    // MARK: - In step with the picture

    /// ⚠️ THE SYNC CLAIM. A band is made while its frame is still on its way
    /// (`prepare`) and drawn only when the surface puts that frame on screen
    /// (`present`) — not before, however early it is ready.
    @Test func aBandIsDrawnWhenItsFrameIsPresentedAndNotBefore() async throws {
        let rig = try Rig()
        rig.band.setActive(true)
        #expect(rig.band.wantsFramesAhead)
        rig.band.prepare(rig.frame(.red), as: VideoFrameID(1))
        await rig.settle { rig.band.debugReadyCount == 1 }
        #expect(rig.band.debugReadyCount == 1, "guard: the band was never made")
        #expect(rig.target.image === rig.still, "a band was drawn before its frame")
        rig.band.present(VideoFrameID(1))
        #expect(rig.band.isShowingLive)
        #expect(rig.target.image !== rig.still)
        rig.band.setActive(false)
    }

    /// Every frame of a playing clip gets its own band — none skipped, none
    /// drawn twice.
    @Test func everyPresentedFrameGetsItsOwnBand() async throws {
        let rig = try Rig()
        rig.band.setActive(true)
        var shown: [UIImage] = []
        for serial in 1...30 {
            let id = VideoFrameID(serial)
            rig.band.prepare(rig.frame(serial.isMultiple(of: 2) ? .red : .blue), as: id)
            await rig.settle { rig.band.debugReadyCount == 1 }
            rig.band.present(id)
            if let image = rig.target.image { shown.append(image) }
        }
        #expect(rig.band.debugDeliveredCount == 30)
        #expect(Set(shown.map(ObjectIdentifier.init)).count == 30)
        // And the colour on screen is the frame's, not its neighbour's.
        let last = try #require(rig.target.image.flatMap(Self.averageColour))
        #expect(last.r > last.b, "frame 30 is red, the band shows \(last)")
        rig.band.setActive(false)
    }

    /// A band not ready when its frame goes on screen is drawn as soon as it
    /// is: late, but for the frame the picture is still on.
    @Test func aBandLateForItsFrameIsDrawnOnArrival() async throws {
        let rig = try Rig(slowReduce: true)
        rig.band.setActive(true)
        rig.band.prepare(rig.frame(.red), as: VideoFrameID(1))
        rig.band.present(VideoFrameID(1))
        #expect(rig.target.image === rig.still)
        await rig.settle { rig.band.isShowingLive }
        #expect(rig.band.isShowingLive)
        rig.band.setActive(false)
    }

    /// A band that lands after the picture has moved on to a later frame is
    /// never drawn: it would put the band behind the picture.
    @Test func aBandForAFrameThePictureHasLeftIsNeverDrawn() async throws {
        let rig = try Rig(slowReduce: true)
        rig.band.setActive(true)
        rig.band.prepare(rig.frame(.red), as: VideoFrameID(1))
        rig.band.prepare(rig.frame(.blue), as: VideoFrameID(2))
        rig.band.present(VideoFrameID(1))
        rig.band.present(VideoFrameID(2))
        await rig.settle { rig.band.debugInFlightCount == 0 }
        #expect(rig.band.debugDeliveredCount == 1, "\(rig.band.debugDeliveredCount) bands drawn")
        let shown = try #require(rig.target.image.flatMap(Self.averageColour))
        #expect(shown.b > shown.r, "frame 2 is blue, the band shows \(shown)")
        rig.band.setActive(false)
    }

    /// Only the FIRST live band fades in over the still; after that the band
    /// changes with its frame, on the spot. A fade between frames is a band
    /// that is always partly the previous frame.
    @Test func afterTheFirstBandFramesChangeWithoutAnimation() async throws {
        let rig = try Rig()
        rig.band.setActive(true)
        rig.band.prepare(rig.frame(.red), as: VideoFrameID(1))
        await rig.settle { rig.band.debugReadyCount == 1 }
        rig.band.present(VideoFrameID(1))
        #expect(rig.band.debugLastFade == LiveMediaBackdrop.firstLiveFade, "the first band did not fade in")
        for serial in 2...4 {
            rig.band.prepare(rig.frame(.blue), as: VideoFrameID(serial))
            await rig.settle { rig.band.debugReadyCount == 1 }
            rig.band.present(VideoFrameID(serial))
            #expect(rig.band.debugLastFade == 0, "frame \(serial) faded over \(rig.band.debugLastFade)s")
        }
        rig.band.setActive(false)
    }

    /// At most `maxInFlight` frames are ever being made: a reducer that falls
    /// behind skips frames rather than queueing up a backlog of the past.
    @Test func aReducerThatFallsBehindIsNotQueuedUp() async throws {
        let rig = try Rig(slowReduce: true)
        rig.band.setActive(true)
        for serial in 1...10 {
            rig.band.prepare(rig.frame(.red), as: VideoFrameID(serial))
        }
        #expect(rig.band.debugInFlightCount == LiveMediaBackdrop.maxInFlight)
        rig.band.setActive(false)
    }

    // MARK: - Lifecycle

    /// A page that stops being watched keeps the frame it paused on — its
    /// picture is paused on that same frame — and stops following.
    @Test func leavingTheScreenStopsFollowingAndKeepsTheFrame() async throws {
        let rig = try Rig()
        try await rig.goLive()
        let live = rig.target.image
        rig.band.setActive(false)
        #expect(!rig.band.isRunning)
        #expect(!rig.band.wantsFramesAhead)
        #expect(rig.target.image === live)
        // A still arriving meanwhile (a re-decided framing) is kept for later
        // and does not overwrite the frame on screen.
        rig.band.setStill(Self.solid(.blue, CGSize(width: 4, height: 4)))
        #expect(rig.target.image === live)
    }

    /// A band still being made when its page leaves is dropped, not drawn.
    @Test func aBandInFlightWhenThePageLeavesIsDropped() async throws {
        let rig = try Rig(slowReduce: true)
        rig.band.setActive(true)
        rig.band.prepare(rig.frame(.red), as: VideoFrameID(1))
        rig.band.present(VideoFrameID(1))
        rig.band.setActive(false)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!rig.band.isShowingLive)
        #expect(rig.target.image === rig.still)
    }

    /// A recycled card, or a new post: the still, at once.
    @Test func returningToTheStillPutsThePosterBack() async throws {
        let rig = try Rig()
        try await rig.goLive()
        rig.band.setActive(false)
        rig.band.returnToStill()
        #expect(!rig.band.isShowingLive)
        #expect(rig.target.image === rig.still)
    }

    /// The surface went back to its poster (a stopped player): so does the
    /// band — and a source that is not drawing gets no frames asked for.
    @Test func aSourceThatStopsDrawingFramesPutsTheStillBack() async throws {
        let rig = try Rig()
        try await rig.goLive()
        rig.source.isShowingLiveFrames = false
        #expect(!rig.band.wantsFramesAhead)
        rig.band.sourceStoppedDrawing()
        #expect(!rig.band.isShowingLive)
        #expect(rig.target.image === rig.still)
        rig.band.prepare(rig.frame(.red), as: VideoFrameID(9))
        #expect(rig.band.debugInFlightCount == 0)
        rig.band.setActive(false)
    }

    /// Reduce Motion or Low Power Mode: the band never starts…
    @Test func reducedMotionOrLowPowerKeepsTheStill() async throws {
        let rig = try Rig()
        rig.band.isSuppressedBySystem = { true }
        rig.band.setActive(true)
        #expect(!rig.band.isRunning)
        #expect(!rig.band.wantsFramesAhead)
        rig.band.prepare(rig.frame(.red), as: VideoFrameID(1))
        rig.band.present(VideoFrameID(1))
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
        try await rig.goLive()
        suppressed = true
        rig.band.debugSettingsChanged()
        #expect(!rig.band.isRunning)
        #expect(!rig.band.isShowingLive)
        #expect(rig.target.image === rig.still)
    }

    /// Nothing is asked for a band nobody can see.
    @Test func aBandOutsideAWindowWantsNoFrames() {
        let rig = try? Rig()
        guard let rig else { Issue.record("rig"); return }
        rig.target.removeFromSuperview()
        rig.band.setActive(true)
        #expect(rig.band.isRunning)
        #expect(!rig.band.wantsFramesAhead)
        rig.band.setActive(false)
    }

    // MARK: - Rig

    @MainActor
    private final class FakeSource: LiveBackdropFrameSource {
        var isShowingLiveFrames = true
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
            band = LiveMediaBackdrop(target: target)
            band.source = source
            band.isSuppressedBySystem = { false }
            if slowReduce {
                band.reduce = { buffer in
                    Thread.sleep(forTimeInterval: 0.1)
                    return BackdropFrameReducer.shared.backdrop(from: buffer)
                }
            }
            band.setStill(still)
        }

        func frame(_ colour: UIColor) -> CVPixelBuffer {
            LiveMediaBackdropTests.bgraBuffer(colour, CGSize(width: 64, height: 80))!
        }

        /// Running, with a first live band on screen.
        func goLive() async throws {
            band.setActive(true)
            band.prepare(frame(.red), as: VideoFrameID(1))
            await settle { band.debugReadyCount == 1 }
            band.present(VideoFrameID(1))
            try #require(band.isShowingLive, "guard: the band never went live")
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
