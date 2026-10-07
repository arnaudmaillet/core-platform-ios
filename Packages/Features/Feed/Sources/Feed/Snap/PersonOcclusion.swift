import AVFoundation
import CoreImage
import CoreStorage
import DesignSystem
import MediaPlayback
import UIKit
import Vision

/// "Don't Cover People" (#484): the reaction band flows BEHIND the people in
/// a playing clip. Vision finds them a few times a second on the frame the
/// page is already showing, and the band is masked where they are.

/// When segmentation may run. Pure, so the rules are tested one by one.
enum PersonOcclusionGate {
    struct Inputs: Equatable {
        /// The viewer's "Don't Cover People".
        var enabled: Bool
        /// The reaction band is on and streaming on this page.
        var bandShown: Bool
        /// The page owns the screen, on screen, with the app in front.
        var pageActive: Bool
        /// Its clip is playing (a paused clip keeps its last mask).
        var playing: Bool
        /// A hero flight carries the page.
        var inFlight: Bool
        var powerSaving: Bool
        var lowPowerMode: Bool
        var thermalState: ProcessInfo.ThermalState
    }

    static func isOpen(_ inputs: Inputs) -> Bool {
        inputs.enabled && inputs.bandShown && inputs.pageActive && inputs.playing && !inputs.inFlight
            && !inputs.powerSaving && !inputs.lowPowerMode && inputs.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue
    }

    /// How often a frame is segmented while the gate is open.
    static let frequency: Double = 8
}

/// Where a picture of `size` lands inside `bounds` for a video gravity.
enum PersonOcclusionGeometry {
    static func displayedRect(of size: CGSize, in bounds: CGRect, gravity: AVLayerVideoGravity) -> CGRect {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scaleX = bounds.width / size.width, scaleY = bounds.height / size.height
        let scale: CGFloat
        switch gravity {
        case .resizeAspect: scale = min(scaleX, scaleY)
        case .resizeAspectFill: scale = max(scaleX, scaleY)
        default: return bounds
        }
        let width = size.width * scale, height = size.height * scale
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }

    /// The band's mask: opaque everywhere (the band shows) except where the
    /// person mask, drawn over `imageRect`, says there is someone. Outside the
    /// picture — letterbox bars — the band is never cut. Updated in place, so
    /// a new mask cross-fades from the last one.
    final class MaskLayer: CALayer {
        let surround = CAShapeLayer()
        let picture = CALayer()

        override init() {
            super.init()
            surround.fillRule = .evenOdd
            surround.fillColor = UIColor.black.cgColor
            picture.contentsGravity = .resize
            addSublayer(surround)
            addSublayer(picture)
        }

        override init(layer: Any) { super.init(layer: layer) }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        func update(bounds newBounds: CGRect, imageRect: CGRect, image: CGImage, fade: Double) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            frame = newBounds
            surround.frame = newBounds
            let path = UIBezierPath(rect: newBounds)
            path.append(UIBezierPath(rect: imageRect))
            surround.path = path.cgPath
            picture.frame = imageRect
            CATransaction.commit()
            // Contents alone animate: a moving subject reads as one shape
            // following them, not as cut-outs jumping several times a second.
            CATransaction.begin()
            CATransaction.setAnimationDuration(fade)
            picture.contents = image
            CATransaction.commit()
        }
    }
}

/// Finds people in a frame, off the main thread, one frame at a time.
final class PersonSegmenter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "cn.wynn.person-segmentation", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var busy = false

    /// An image whose ALPHA is the band's: opaque where nobody is, clear on
    /// people. Nil when a frame is still being worked on (this one is
    /// dropped, never queued) or nothing could be read.
    func mask(for buffer: CVPixelBuffer) async -> CGImage? {
        let claimed: Bool = lock.withLock {
            guard !busy else { return false }
            busy = true
            return true
        }
        guard claimed else { return nil }
        nonisolated(unsafe) let frame = buffer
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                let image = Self.invertedMask(frame, context: context)
                lock.withLock { busy = false }
                continuation.resume(returning: image)
            }
        }
    }

    private static func invertedMask(_ buffer: CVPixelBuffer, context: CIContext) -> CGImage? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, options: [:])
        guard (try? handler.perform([request])) != nil,
              let mask = request.results?.first?.pixelBuffer else { return nil }
        // Person = white in the mask; the band wants the opposite, as alpha.
        let inverted = CIImage(cvPixelBuffer: mask)
            .applyingFilter("CIColorInvert")
            .applyingFilter("CIMaskToAlpha")
        return context.createCGImage(inverted, from: inverted.extent)
    }
}

/// Runs segmentation for one page while its gate is open, and masks its band.
@MainActor
final class PersonOcclusionDriver {
    /// What one beat does.
    enum Decision: Equatable {
        /// Segment the frame showing now.
        case segment
        /// Do nothing, keep the last mask: a paused clip still shows the same
        /// people.
        case hold
        /// Remove the mask: the setting is off, the band gone, or the device
        /// asks for less work.
        case clear
    }

    /// The beat's decision for the gate's inputs.
    static func decision(for inputs: PersonOcclusionGate.Inputs) -> Decision {
        if PersonOcclusionGate.isOpen(inputs) { return .segment }
        var paused = inputs
        paused.playing = true
        // Only "not playing" closed it: hold the picture's mask.
        return PersonOcclusionGate.isOpen(paused) ? .hold : .clear
    }

    /// Asked on every beat; `.segment` when unset.
    var decide: (() -> Decision)?
    private let segmenter = PersonSegmenter()
    private var timer: Timer?
    private weak var surface: VideoRenderView?
    private weak var band: UIView?
    private var generation = 0

    var isRunning: Bool { timer != nil }

    #if DEBUG
    /// `-occlusion-log`: when the driver runs, stops, and what each mask covers.
    static let traces = ProcessInfo.processInfo.arguments.contains("-occlusion-log")
    private func trace(_ message: @autoclosure () -> String) {
        guard Self.traces else { return }
        print(String(format: "[occlusion] %.3f %@", CACurrentMediaTime(), message()))
    }
    #endif

    /// Starts (or keeps) segmenting `surface`'s frames for `band`.
    func run(surface: VideoRenderView, band: UIView) {
        if self.surface !== surface || self.band !== band { clearMask() }
        self.surface = surface
        self.band = band
        guard timer == nil else { return }
        #if DEBUG
        trace("run band=\(band.bounds.size) surface=\(surface.bounds.size)")
        #endif
        let timer = Timer(timeInterval: 1 / PersonOcclusionGate.frequency, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    /// Stops segmenting. A paused clip keeps its last mask (`keepMask`), so
    /// the band does not flash over a still face; anything else removes it.
    func stop(keepMask: Bool = false) {
        #if DEBUG
        if timer != nil { trace("stop keepMask=\(keepMask)") }
        #endif
        timer?.invalidate()
        timer = nil
        generation += 1
        if !keepMask { clearMask() }
    }

    private func clearMask() {
        band?.layer.mask = nil
    }

    #if DEBUG
    private var lastDecision: Decision?
    #endif

    private func tick() {
        let decision = decide?() ?? .segment
        #if DEBUG
        if decision != lastDecision { trace("decision \(decision)") }
        lastDecision = decision
        #endif
        switch decision {
        case .segment: break
        case .hold: return
        case .clear:
            clearMask()
            return
        }
        guard let surface, let band, let buffer = surface.currentFrameBuffer else {
            #if DEBUG
            trace("no frame")
            #endif
            return
        }
        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        let generation = generation
        // ⚠️ Borrowed from the renderer's pool: read once by Vision, on the
        // segmenter's queue, and never written — the only use of this
        // reference, and it dies with that one request.
        nonisolated(unsafe) let frame = buffer
        Task { [weak self] in
            guard let image = await self?.segmenter.mask(for: frame), let self,
                  generation == self.generation else { return }
            apply(image, pictureSize: size, surface: surface, band: band)
        }
    }

    private func apply(_ image: CGImage, pictureSize: CGSize, surface: VideoRenderView, band: UIView) {
        guard surface.window != nil, band.window != nil else { return }
        let picture = PersonOcclusionGeometry.displayedRect(of: pictureSize, in: surface.bounds, gravity: surface.videoGravity)
        let imageRect = surface.convert(picture, to: band)
        let mask = band.layer.mask as? PersonOcclusionGeometry.MaskLayer ?? PersonOcclusionGeometry.MaskLayer()
        mask.update(bounds: band.bounds, imageRect: imageRect, image: image, fade: 1 / PersonOcclusionGate.frequency)
        if band.layer.mask !== mask { band.layer.mask = mask }
        #if DEBUG
        trace("mask \(image.width)x\(image.height) picture=\(imageRect.integral) band=\(band.bounds.size)")
        #endif
    }
}
