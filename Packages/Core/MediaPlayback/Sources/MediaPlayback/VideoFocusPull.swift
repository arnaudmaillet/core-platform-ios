import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import UIKit

/// A surface's picture coming up in resolution, from a few pixels per point to
/// the screen's (#625).
///
/// A hero flight hands a low-resolution picture — a map marker's baked
/// preview sheet — over to the live video. Cross-fading the two shows both at
/// once: the same moment of the clip at two sharpnesses, which reads as one
/// picture ghosting over another. This draws the live video's own frames at
/// the sheet's resolution instead, and raises it: the hand-over is between two
/// pictures that match, and the sharpening that follows reads as focus.
///
/// ⚠️ THE FRAMES, NOT THE LAYER. The sample-buffer layer's content is
/// composited out of process and does not survive `shouldRasterize` — tried,
/// filmed: the video went black for a second. The renderer already retains
/// the buffer on screen (`VideoRenderView.currentFrameBuffer`), so this
/// downsamples THAT, on the GPU, into a small image over the layer. Nothing
/// exists at rest; during the pull it is one small render per new frame.
///
/// The ramp stops short of the screen's resolution and fades the overlay out
/// instead — the last steps would be full-size renders for a difference the
/// fade covers.
@MainActor
final class VideoFocusPull {
    /// One render at a time, the latest frame wins.
    nonisolated private static let queue = DispatchQueue(label: "VideoFocusPull", qos: .userInteractive)
    /// Shared and created once, for the reason `VideoStillCapture` gives.
    nonisolated private static let context = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: false])

    private let overlay = UIImageView()
    private weak var surface: VideoRenderView?
    private let start: CGFloat
    private let end: CGFloat
    private let duration: CFTimeInterval
    private var startTime: CFTimeInterval = 0
    private var link: CADisplayLink?
    private var isRendering = false
    /// The clip time of the frame last drawn. ⚠️ A TIME, NOT THE BUFFER: the
    /// buffer is borrowed from the decoder's pool (`currentFrameBuffer`), so
    /// keeping it is a buffer the decoder allocates around — and the pool
    /// recycles buffers, so its identity does not say "new frame" anyway.
    private var lastFrameTime: TimeInterval?
    private var lastResolution: CGFloat = 0
    private let onEnd: () -> Void

    /// Nil when the surface has no frame of its own to draw from (no
    /// renderer: `-avplayer-render`), or no size yet.
    init?(surface: VideoRenderView, from start: CGFloat, over duration: CFTimeInterval, onEnd: @escaping () -> Void) {
        guard let buffer = surface.currentFrameBuffer, surface.bounds.width > 0, surface.bounds.height > 0,
              let end = Self.endResolution(start: start, screenScale: surface.traitCollection.displayScale)
        else { return nil }
        self.surface = surface
        self.start = start
        self.end = end
        self.duration = duration
        self.onEnd = onEnd
        overlay.frame = surface.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.contentMode = surface.videoGravity == .resizeAspect ? .scaleAspectFit : .scaleAspectFill
        overlay.clipsToBounds = true
        overlay.isUserInteractionEnabled = false
        // As the sheet draws (`AnimatedIconView`): the same few pixels,
        // magnified the same way.
        overlay.layer.magnificationFilter = .trilinear
        overlay.layer.minificationFilter = .trilinear
        // The first picture NOW, on the main thread: the overlay has to be up
        // in the frame the video starts showing, or the hand-over is to a
        // sharp picture after all. It is the smallest render of the pull.
        guard let first = Self.render(buffer, scale: Self.bufferScale(buffer: buffer, bounds: surface.bounds, pixelsPerPoint: start)) else { return nil }
        overlay.image = UIImage(cgImage: first.image)
        lastFrameTime = surface.displayedClipTime
        lastResolution = start
        surface.addSubview(overlay)
        startTime = CACurrentMediaTime()
        let link = CADisplayLink(target: LinkTarget(pull: self), selector: #selector(LinkTarget.tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Ends the pull now: the overlay goes, the live picture shows as it is.
    func cancel() {
        guard link != nil else { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") { print("[focus-pull] end") }
        #endif
        link?.invalidate()
        link = nil
        overlay.removeFromSuperview()
        onEnd()
    }

    fileprivate func tick() {
        guard let surface, let buffer = surface.currentFrameBuffer else { return cancel() }
        let progress = min(1, (CACurrentMediaTime() - startTime) / duration)
        overlay.alpha = Self.overlayAlpha(at: progress)
        guard progress < 1 else { return cancel() }
        let resolution = Self.resolution(at: progress, from: start, to: end)
        // A new frame, or a sharper step: either changes the picture.
        let frameTime = surface.displayedClipTime
        guard !isRendering, frameTime != lastFrameTime || resolution > lastResolution * 1.05 else { return }
        isRendering = true
        lastFrameTime = frameTime
        lastResolution = resolution
        let scale = Self.bufferScale(buffer: buffer, bounds: surface.bounds, pixelsPerPoint: resolution)
        let source = Rendering(buffer: buffer)
        Self.queue.async { [weak self] in
            let image = Self.render(source.buffer, scale: scale)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isRendering = false
                    guard self.link != nil, let image else { return }
                    self.overlay.image = UIImage(cgImage: image.image)
                }
            }
        }
    }

    // MARK: - The ramp, as arithmetic

    /// Where the ramp stops, in pixels per point: well short of the screen,
    /// the overlay fading out over the rest. Nil when the start is already
    /// near the screen's resolution — nothing to pull.
    nonisolated static func endResolution(start: CGFloat, screenScale: CGFloat) -> CGFloat? {
        guard start > 0, screenScale > 0, start < screenScale * 0.6 else { return nil }
        return max(start, min(screenScale * 0.5, 1.5))
    }

    /// The resolution at `progress` (0…1): it rises over the first 60% of the
    /// pull, eased out — most of the detail arrives early.
    nonisolated static func resolution(at progress: Double, from start: CGFloat, to end: CGFloat) -> CGFloat {
        let t = min(1, max(0, progress / 0.6))
        let eased = 1 - (1 - t) * (1 - t)
        return start + (end - start) * CGFloat(eased)
    }

    /// The overlay's opacity at `progress`: whole until 40%, gone at 100%.
    nonisolated static func overlayAlpha(at progress: Double) -> CGFloat {
        let t = min(1, max(0, (progress - 0.4) / 0.6))
        return CGFloat(1 - t)
    }

    /// The scale to apply to the decoded buffer so it shows `pixelsPerPoint`
    /// once the overlay lays it over `bounds` under aspect-fill. Never above
    /// the buffer's own resolution.
    nonisolated static func bufferScale(bufferSize: CGSize, bounds: CGSize, pixelsPerPoint: CGFloat) -> CGFloat {
        guard bufferSize.width > 0, bufferSize.height > 0 else { return 1 }
        let pointsPerPixel = max(bounds.width / bufferSize.width, bounds.height / bufferSize.height)
        return min(1, pixelsPerPoint * pointsPerPixel)
    }

    nonisolated private static func bufferScale(buffer: CVPixelBuffer, bounds: CGRect, pixelsPerPoint: CGFloat) -> CGFloat {
        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        return bufferScale(bufferSize: size, bounds: bounds.size, pixelsPerPoint: pixelsPerPoint)
    }

    nonisolated private static func render(_ buffer: CVPixelBuffer, scale: CGFloat) -> Rendered? {
        let source = CIImage(cvPixelBuffer: buffer)
        let size = CGSize(width: max(1, (source.extent.width * scale).rounded(.down)),
                          height: max(1, (source.extent.height * scale).rounded(.down)))
        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = source.clampedToExtent()
        filter.scale = Float(scale)
        filter.aspectRatio = 1
        guard let output = filter.outputImage?.cropped(to: CGRect(origin: .zero, size: size)),
              let image = context.createCGImage(output, from: output.extent) else { return nil }
        return Rendered(image: image)
    }

    /// A decoded buffer handed to the render queue: read there, never written.
    private struct Rendering: @unchecked Sendable { let buffer: CVPixelBuffer }
    private struct Rendered: @unchecked Sendable { let image: CGImage }

    /// A display link retains its target, so the pull is held weakly and the
    /// link ends itself when the pull goes.
    private final class LinkTarget: NSObject {
        weak var pull: VideoFocusPull?
        init(pull: VideoFocusPull) { self.pull = pull }
        @MainActor @objc func tick(_ link: CADisplayLink) {
            guard let pull else { return link.invalidate() }
            pull.tick()
        }
    }
}

public extension VideoRenderView {
    /// Warms the pull's GPU context off the main thread, so the first pull
    /// does not pay for creating it mid-flight. Cheap to call again.
    nonisolated static func prewarmFocusPull() {
        VideoFocusPull.prewarm()
    }
}

extension VideoFocusPull {
    nonisolated static func prewarm() {
        queue.async { _ = context.workingColorSpace }
    }
}
