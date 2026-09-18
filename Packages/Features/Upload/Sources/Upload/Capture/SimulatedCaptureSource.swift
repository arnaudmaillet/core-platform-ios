import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Synchronization
import UIKit
import UniformTypeIdentifiers

/// The camera wherever there is none — every simulator — drawing a moving
/// scene of its own and writing REAL files from it: a JPEG for a photograph,
/// an H.264 movie for each clip, recorded in real time for exactly as long as
/// the shutter was held.
///
/// ⚠️ **WRITTEN FRAME BY FRAME AS THEY ARE SHOWN, NOT SYNTHESISED AFTER THE
/// FACT.** `PlaceholderVideoFetcher` makes a clip of a fixed length for a URL;
/// a capture's length is the length of a hold, which nobody knows until the
/// finger lifts. So the frames the preview draws are the frames the writer
/// appends, stamped with the host clock — a two-second hold is a two-second
/// file, and the ring, the three-minute cap and the stitch are exercised with
/// the durations a phone would produce.
///
/// ⚠️ **EVERY CONTROL CHANGES THE PICTURE, OR IT COULD NOT BE CHECKED BY EYE.**
/// Zoom scales the scene about its centre (0.5 shows more of it, as the
/// ultra-wide does), flip swaps to a different scene, the torch brightens the
/// frames it lights, a flash photograph is brighter than one without, and a
/// caption at the top spells the camera and the zoom.
///
/// ⚠️ **COLOUR-TAGGED CLIPS.** Rec. 709, stated — `PlaceholderVideoFetcher`
/// records what an untagged clip costs: `AVSampleBufferDisplayLayer` accepts
/// the buffers and draws black.
@MainActor
final class SimulatedCaptureSource: CaptureSource {
    let feed = CaptureFrameFeed()
    private let engine: SimulatedCaptureEngine

    init(frameSize: CGSize = SimulatedCaptureEngine.frameSize) {
        engine = SimulatedCaptureEngine(feed: feed, frameSize: frameSize)
    }

    func authorize() async -> CaptureAuthorization { .authorized(microphone: false) }

    func start() { engine.start() }
    func stop() { engine.stop() }

    /// Every frame goes through the feed: the simulated scene has no cheaper
    /// surface to offer, and the renderer's own cost is what was measured.
    var plainPreview: UIView? { nil }

    var onStateChange: (() -> Void)?

    private(set) var position: CapturePosition = .back

    func flip() async {
        position = position.flipped
        engine.setPosition(position)
        setZoom(1, smoothly: false)
        onStateChange?()
    }

    var lenses: [CaptureLens] {
        position == .back
            ? [CaptureLens(factor: 0.5), CaptureLens(factor: 1), CaptureLens(factor: 2), CaptureLens(factor: 3)]
            : [CaptureLens(factor: 1)]
    }

    var zoomRange: ClosedRange<CGFloat> { position == .back ? 0.5...10 : 1...4 }

    private(set) var zoom: CGFloat = 1

    func setZoom(_ factor: CGFloat, smoothly: Bool) {
        zoom = min(max(factor, zoomRange.lowerBound), zoomRange.upperBound)
        engine.setZoom(zoom, smoothly: smoothly)
    }

    func focus(at point: CGPoint) {}

    var hasFlash: Bool { true }

    func capturePhoto(flash: CaptureFlashMode, into folder: CaptureFolder) async throws -> CapturedPhoto {
        let url = folder.newFile("capture", pathExtension: "jpg")
        return try await engine.photograph(to: url, flash: flash != .off)
    }

    func startRecording(to url: URL, torch: Bool, limit: TimeInterval) -> CaptureClipPromise {
        engine.record(to: url, torch: torch, limit: limit)
    }

    func stopRecording() { engine.stopRecording() }

    var recordedDuration: TimeInterval { engine.recordedDuration }

    /// Always on: the feed is this source's only preview.
    func setDeliversFrames(_ on: Bool) {}
}

/// The simulated camera's moving parts, on a queue of their own.
///
/// ⚠️ **NOT MAIN-ACTOR ISOLATED, AND THAT IS STRUCTURAL.** Every closure handed
/// to the timer and to `AVAssetWriter` is formed in here, in a nonisolated
/// context. Formed inside a `@MainActor` type instead, the same closure
/// compiles and TRAPS the first time the queue runs it
/// (`dispatch_assert_queue_fail`) — the repository has two instances of that
/// with PhotoKit. State the main actor writes is behind a `Mutex`.
final class SimulatedCaptureEngine: @unchecked Sendable {
    /// Portrait 720p: enough to fill a phone-sized preview, cheap to draw.
    static let frameSize = CGSize(width: 720, height: 1280)
    static let framesPerSecond: Int32 = 30
    /// The photograph is drawn fresh at this size, not scaled up from a frame.
    static let photoSize = CGSize(width: 1080, height: 1920)

    private struct State {
        var position: CapturePosition = .back
        var zoom: CGFloat = 1
        var targetZoom: CGFloat = 1
        var torch = false
    }

    private final class Recording {
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let limit: TimeInterval
        var firstTime: CMTime?
        var lastTime: CMTime?
        var stopRequested = false
        let continuation: CaptureClipPromise

        init(
            writer: AVAssetWriter, input: AVAssetWriterInput,
            adaptor: AVAssetWriterInputPixelBufferAdaptor, limit: TimeInterval,
            continuation: CaptureClipPromise
        ) {
            self.writer = writer
            self.input = input
            self.adaptor = adaptor
            self.limit = limit
            self.continuation = continuation
        }
    }

    private let feed: CaptureFrameFeed
    private let size: CGSize
    private let queue = DispatchQueue(label: "capture.simulated", qos: .userInitiated)
    private let state = Mutex(State())
    private let elapsed = Mutex<TimeInterval>(0)
    /// Touched on `queue` only.
    private var timer: DispatchSourceTimer?
    private var pool: CVPixelBufferPool?
    private var recording: Recording?
    private let startedAt = CACurrentMediaTime()

    init(feed: CaptureFrameFeed, frameSize: CGSize) {
        self.feed = feed
        self.size = frameSize
    }

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(
                deadline: .now(), repeating: .nanoseconds(Int(1_000_000_000 / Self.framesPerSecond)),
                leeway: .milliseconds(2)
            )
            source.setEventHandler { [weak self] in self?.tick() }
            source.resume()
            timer = source
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            if let recording { finish(recording) }
        }
    }

    deinit {
        timer?.cancel()
    }

    func setPosition(_ position: CapturePosition) {
        state.withLock {
            $0.position = position
            $0.zoom = 1
            $0.targetZoom = 1
        }
    }

    func setZoom(_ zoom: CGFloat, smoothly: Bool) {
        state.withLock {
            $0.targetZoom = zoom
            if !smoothly { $0.zoom = zoom }
        }
    }

    var recordedDuration: TimeInterval { elapsed.withLock { $0 } }

    // MARK: - Frames

    private func tick() {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let current = state.withLock { state -> State in
            // A chip's jump eases in over a few frames, the way a lens ramp does.
            state.zoom += (state.targetZoom - state.zoom) * 0.25
            if abs(state.targetZoom - state.zoom) < 0.005 { state.zoom = state.targetZoom }
            return state
        }
        guard let buffer = makeBuffer() else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer),
           let context = CGContext(
               data: base, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
               bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
               space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
           ) {
            SimulatedCameraScene.draw(
                in: context, size: size, time: CACurrentMediaTime() - startedAt,
                position: current.position, zoom: current.zoom, lit: current.torch
            )
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        feed.deliver(CaptureFrame(pixelBuffer: buffer, time: now, isMirrored: false))
        if let recording { append(buffer, at: now, to: recording) }
    }

    private func makeBuffer() -> CVPixelBuffer? {
        if pool == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                // ⚠️ IOSURFACE-BACKED, so Core Image hands it to Metal without a
                // copy — the renderer's cost is then the look, not an upload.
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
            ]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }

    // MARK: - Photograph

    func photograph(to url: URL, flash: Bool) async throws -> CapturedPhoto {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                let current = state.withLock { $0 }
                let photo = Self.photoSize
                guard let context = CGContext(
                    data: nil, width: Int(photo.width), height: Int(photo.height), bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                ) else {
                    continuation.resume(throwing: CaptureSourceError.photoFailed)
                    return
                }
                SimulatedCameraScene.draw(
                    in: context, size: photo, time: CACurrentMediaTime() - startedAt,
                    position: current.position, zoom: current.zoom, lit: flash
                )
                guard let image = context.makeImage(),
                      let destination = CGImageDestinationCreateWithURL(
                          url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
                      )
                else {
                    continuation.resume(throwing: CaptureSourceError.photoFailed)
                    return
                }
                CGImageDestinationAddImage(
                    destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
                )
                guard CGImageDestinationFinalize(destination) else {
                    continuation.resume(throwing: CaptureSourceError.photoFailed)
                    return
                }
                continuation.resume(returning: CapturedPhoto(url: url, uprightSize: photo))
            }
        }
    }

    // MARK: - Recording

    func record(to url: URL, torch: Bool, limit: TimeInterval) -> CaptureClipPromise {
        let promise = CaptureClipPromise()
        queue.async { [self] in
            guard recording == nil,
                  let writer = try? AVAssetWriter(outputURL: url, fileType: .mov)
            else {
                promise.fulfil(.failure(CaptureSourceError.recordingFailed))
                return
            }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height),
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
                ]
            ])
            input.expectsMediaDataInRealTime = true
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
            guard writer.canAdd(input) else {
                promise.fulfil(.failure(CaptureSourceError.recordingFailed))
                return
            }
            writer.add(input)
            guard writer.startWriting() else {
                promise.fulfil(.failure(CaptureSourceError.recordingFailed))
                return
            }
            state.withLock { $0.torch = torch }
            elapsed.withLock { $0 = 0 }
            recording = Recording(writer: writer, input: input, adaptor: adaptor, limit: limit, continuation: promise)
        }
        return promise
    }

    func stopRecording() {
        queue.async { [self] in
            recording?.stopRequested = true
        }
    }

    private func append(_ buffer: CVPixelBuffer, at time: CMTime, to recording: Recording) {
        if recording.firstTime == nil {
            recording.writer.startSession(atSourceTime: time)
            recording.firstTime = time
        }
        guard let first = recording.firstTime else { return }
        let length = (time - first).seconds
        // ⚠️ THE LIMIT IS CHECKED BEFORE THE FRAME IS WRITTEN, so a clip stopped
        // by it never runs past it by the frame that noticed.
        if recording.stopRequested || length >= recording.limit {
            finish(recording)
            return
        }
        if recording.input.isReadyForMoreMediaData, recording.adaptor.append(buffer, withPresentationTime: time) {
            recording.lastTime = time
        }
        elapsed.withLock { $0 = length }
    }

    private func finish(_ recording: Recording) {
        self.recording = nil
        state.withLock { $0.torch = false }
        guard let first = recording.firstTime, let last = recording.lastTime else {
            recording.writer.cancelWriting()
            elapsed.withLock { $0 = 0 }
            // Nothing was written: a zero-length clip, which the take refuses.
            recording.continuation.fulfil(.success(CaptureClip(url: recording.writer.outputURL, duration: 0)))
            return
        }
        let frame = CMTime(value: 1, timescale: Self.framesPerSecond)
        let end = last + frame
        recording.writer.endSession(atSourceTime: end)
        recording.input.markAsFinished()
        let duration = (end - first).seconds
        let writer = WriterBox(writer: recording.writer)
        let continuation = recording.continuation
        writer.writer.finishWriting { [self] in
            elapsed.withLock { $0 = 0 }
            if writer.writer.status == .completed {
                continuation.fulfil(.success(CaptureClip(url: writer.writer.outputURL, duration: duration)))
            } else {
                continuation.fulfil(.failure(CaptureSourceError.recordingFailed))
            }
        }
    }
}

/// ⚠️ `AVAssetWriter` IS NOT `Sendable`; its completion handler is. The writer
/// is finished — nothing else touches it — by the time the handler reads it.
private struct WriterBox: @unchecked Sendable {
    let writer: AVAssetWriter
}

/// The picture the simulated camera films.
///
/// ⚠️ **DRAWN WITH CORE GRAPHICS CALLS ON THE CONTEXT, NEVER `UIColor.setFill()`**
/// — the trap `PlaceholderVideoFetcher` fell into for its whole life: that call
/// fills the CURRENT UIKit context, which a hand-made bitmap context is not,
/// and every frame came out black. Text is the one UIKit drawing here, and it
/// pushes the context first.
enum SimulatedCameraScene {
    static func draw(
        in context: CGContext, size: CGSize, time: TimeInterval,
        position: CapturePosition, zoom: CGFloat, lit: Bool
    ) {
        let width = size.width
        let height = size.height
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        // The sky fills the frame at any zoom, so a wide view never shows an edge.
        let sky: [CGColor] = position == .back
            ? [UIColor(red: 0.10, green: 0.22, blue: 0.52, alpha: 1).cgColor,
               UIColor(red: 0.98, green: 0.62, blue: 0.36, alpha: 1).cgColor]
            : [UIColor(red: 0.52, green: 0.18, blue: 0.46, alpha: 1).cgColor,
               UIColor(red: 0.98, green: 0.70, blue: 0.62, alpha: 1).cgColor]
        if let gradient = CGGradient(colorsSpace: space, colors: sky as CFArray, locations: [0, 1]) {
            // Bitmap contexts are y-up: the first colour at the TOP.
            context.drawLinearGradient(
                gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: 0, y: 0), options: []
            )
        }

        context.saveGState()
        // Zoom about the centre: 0.5 draws the world at half size, showing more.
        context.translateBy(x: width / 2, y: height / 2)
        context.scaleBy(x: zoom, y: zoom)
        context.translateBy(x: -width / 2, y: -height / 2)

        if position == .back {
            drawLandscape(in: context, width: width, height: height, time: time)
        } else {
            drawFace(in: context, width: width, height: height, time: time)
        }
        context.restoreGState()

        if lit {
            context.setBlendMode(.screen)
            context.setFillColor(UIColor(white: 1, alpha: 0.28).cgColor)
            context.fill(CGRect(origin: .zero, size: size))
            context.setBlendMode(.normal)
        }

        drawCaption(in: context, size: size, position: position, zoom: zoom, time: time)
    }

    private static func drawLandscape(in context: CGContext, width: CGFloat, height: CGFloat, time: TimeInterval) {
        // A sun on a slow arc.
        let arc = CGFloat(time.truncatingRemainder(dividingBy: 20) / 20) * .pi
        let sun = CGPoint(x: width * (0.2 + 0.6 * (1 - cos(arc)) / 2), y: height * (0.62 + 0.18 * sin(arc)))
        context.setFillColor(UIColor(red: 1, green: 0.88, blue: 0.4, alpha: 1).cgColor)
        context.fillEllipse(in: CGRect(x: sun.x - width * 0.09, y: sun.y - width * 0.09, width: width * 0.18, height: width * 0.18))

        // Hills, wider than the frame so a 0.5 zoom still stands on ground.
        let hills: [(CGFloat, CGFloat, UIColor)] = [
            (0.05, 0.42, UIColor(red: 0.20, green: 0.45, blue: 0.30, alpha: 1)),
            (0.55, 0.36, UIColor(red: 0.16, green: 0.38, blue: 0.26, alpha: 1)),
            (-0.4, 0.30, UIColor(red: 0.12, green: 0.30, blue: 0.20, alpha: 1))
        ]
        for (x, top, colour) in hills {
            context.setFillColor(colour.cgColor)
            context.fillEllipse(in: CGRect(x: width * (x - 0.9), y: -height * 0.6, width: width * 2.2, height: height * (0.6 + top)))
        }

        // Three balls bouncing across, each its own colour and pace.
        let balls: [(UIColor, Double, CGFloat)] = [
            (.systemRed, 1.3, 0.18), (.systemYellow, 0.9, 0.24), (.systemTeal, 1.7, 0.14)
        ]
        for (index, (colour, pace, y)) in balls.enumerated() {
            let phase = time * pace + Double(index) * 2.1
            let x = width * (0.5 + 0.38 * CGFloat(sin(phase)))
            let bounce = height * 0.06 * CGFloat(abs(sin(phase * 2.4)))
            let side = width * 0.1
            context.setFillColor(colour.cgColor)
            context.fillEllipse(in: CGRect(x: x - side / 2, y: height * y + bounce, width: side, height: side))
        }

        // A clock face in the middle: its hand turns once a minute, so a still
        // photograph and a clip each carry the moment they were taken.
        let centre = CGPoint(x: width / 2, y: height * 0.5)
        let radius = width * 0.14
        context.setFillColor(UIColor(white: 1, alpha: 0.85).cgColor)
        context.fillEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
        context.setStrokeColor(UIColor(white: 0.1, alpha: 1).cgColor)
        context.setLineWidth(max(2, width * 0.008))
        let angle = CGFloat(time.truncatingRemainder(dividingBy: 60) / 60) * 2 * .pi
        context.move(to: centre)
        context.addLine(to: CGPoint(x: centre.x + sin(angle) * radius * 0.85, y: centre.y + cos(angle) * radius * 0.85))
        context.strokePath()
    }

    private static func drawFace(in context: CGContext, width: CGFloat, height: CGFloat, time: TimeInterval) {
        let bob = CGFloat(sin(time * 1.6)) * height * 0.015
        let centre = CGPoint(x: width / 2, y: height * 0.5 + bob)
        let radius = width * 0.3
        context.setFillColor(UIColor(red: 0.98, green: 0.80, blue: 0.62, alpha: 1).cgColor)
        context.fillEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2.2))
        // Eyes blink every few seconds.
        let blink = time.truncatingRemainder(dividingBy: 3.5) < 0.15
        context.setFillColor(UIColor(white: 0.15, alpha: 1).cgColor)
        for side in [-1.0, 1.0] as [CGFloat] {
            let eye = CGRect(
                x: centre.x + side * radius * 0.38 - radius * 0.08, y: centre.y + radius * 0.3,
                width: radius * 0.16, height: blink ? radius * 0.03 : radius * 0.2
            )
            context.fillEllipse(in: eye)
        }
        context.setStrokeColor(UIColor(red: 0.7, green: 0.2, blue: 0.25, alpha: 1).cgColor)
        context.setLineWidth(radius * 0.07)
        context.addArc(
            center: CGPoint(x: centre.x, y: centre.y - radius * 0.05), radius: radius * 0.45,
            startAngle: .pi * 1.15, endAngle: .pi * 1.85, clockwise: false
        )
        context.strokePath()
    }

    private static func drawCaption(
        in context: CGContext, size: CGSize, position: CapturePosition, zoom: CGFloat, time: TimeInterval
    ) {
        let side = position == .back ? "BACK" : "FRONT"
        let seconds = Int(time) % 60
        let tenths = Int(time * 10) % 10
        let text = "SIMULATED CAMERA · \(side) · \(String(format: "%.1f", zoom))×\n\(String(format: "%02d.%d", seconds, tenths))s"
        let font = UIFont.monospacedDigitSystemFont(ofSize: size.width * 0.034, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white,
            .paragraphStyle: {
                let style = NSMutableParagraphStyle()
                style.alignment = .center
                return style
            }()
        ]
        context.saveGState()
        // UIKit draws y-down; the bitmap context is y-up.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        (text as NSString).draw(
            in: CGRect(x: 0, y: size.height * 0.16, width: size.width, height: size.width * 0.1),
            withAttributes: attributes
        )
        UIGraphicsPopContext()
        context.restoreGState()
    }
}
