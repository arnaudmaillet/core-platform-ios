import CoreImage
import MediaPlayback
import Metal
import QuartzCore
import Synchronization
import UIKit

/// The live preview when it has to be DRAWN: every camera frame through Core
/// Image — the look, then an aspect fill — straight into a Metal drawable.
///
/// ⚠️ **THE LOOK IS THE EDITOR'S OWN GRAPH.** `FrameLookRenderer.apply` is what
/// the editor's canvas, the photo bake and the video compositor all draw a
/// `FrameLook` with, so the preview shows the look the editor will open on —
/// not an approximation of it.
///
/// ⚠️ **RENDERED ON THE FRAME'S OWN QUEUE, AND LATE FRAMES ARE DROPPED.** A
/// frame arrives on the source's queue and is encoded there; while the GPU is
/// still busy with the last one the new one is skipped rather than queued, so
/// a slow look costs frames, never latency — a preview that lags the hand is
/// worse than one that drops.
///
/// ⚠️ **`VideoLiveLook` IS THE BOARD THE LOOK IS READ FROM**, the compositor's
/// own mechanism: the main actor writes it on a pick, the render queue reads it
/// every frame, and nothing is rebuilt.
@MainActor
final class CaptureLiveView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    private let renderer: CaptureLiveRenderer?

    init() {
        renderer = CaptureLiveRenderer.make()
        super.init(frame: .zero)
        isOpaque = true
        backgroundColor = .black
        if let renderer, let metal = layer as? CAMetalLayer {
            metal.device = renderer.device
            metal.pixelFormat = .bgra8Unorm
            // ⚠️ CORE IMAGE WRITES INTO THE DRAWABLE AS A RENDER TARGET, which a
            // framebuffer-only texture cannot be.
            metal.framebufferOnly = false
            metal.contentsGravity = .resizeAspectFill
            renderer.attach(metal)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? traitCollection.displayScale
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard size.width > 0, size.height > 0 else { return }
        (layer as? CAMetalLayer)?.drawableSize = size
        renderer?.setDrawableSize(size)
    }

    /// What the feed hands each frame to, on the source's queue.
    ///
    /// ⚠️ **FORMED HERE, IN A NONISOLATED FUNCTION, ON PURPOSE.** A closure
    /// written inside a main-actor method can come out main-actor isolated, and
    /// Swift then checks the queue it is called on — a trap on the first frame,
    /// the PhotoKit incident this repository has had twice.
    nonisolated func makeSink() -> @Sendable (CaptureFrame) -> Void {
        let renderer = self.renderer
        return { frame in renderer?.render(frame) }
    }

    func setLook(_ look: FrameLook) {
        renderer?.look.set(look)
    }

    /// A small picture of the latest frame in `look`, for the filter row's
    /// cards. Nil before any frame.
    nonisolated static func snapshot(of frame: CaptureFrame, side: CGFloat) -> UIImage? {
        var image = CIImage(cvPixelBuffer: frame.pixelBuffer)
        if frame.isMirrored {
            image = image.transformed(by: CGAffineTransform(scaleX: -1, y: 1))
                .transformed(by: CGAffineTransform(translationX: image.extent.width, y: 0))
        }
        let extent = image.extent
        let scale = side / min(extent.width, extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let square = CGRect(
            x: scaled.extent.midX - side / 2, y: scaled.extent.midY - side / 2, width: side, height: side
        ).integral
        guard let cgImage = EditingRenderContext.shared.createCGImage(scaled, from: square) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// Internal for tests and the frame-time log: the mean render time over the
    /// last frames, in milliseconds, and how many were drawn / dropped.
    var debugFrameStats: (meanMilliseconds: Double, drawn: Int, dropped: Int) {
        renderer?.stats ?? (0, 0, 0)
    }
}

/// The Metal half of `CaptureLiveView`, touched from the frame queue.
final class CaptureLiveRenderer: Sendable {
    let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let context: CIContext
    let look = VideoLiveLook(.neutral)
    private let target = Mutex<CAMetalLayerBox?>(nil)
    private let drawableSize = Mutex(CGSize.zero)
    private let inFlight = Atomic(false)
    private let timing = Mutex(Timing())
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    private struct Timing {
        var recent: [Double] = []
        var drawn = 0
        var dropped = 0
    }

    /// ⚠️ `CAMetalLayer.nextDrawable()` IS DOCUMENTED SAFE OFF THE MAIN THREAD;
    /// the box only carries the reference across.
    private struct CAMetalLayerBox: @unchecked Sendable {
        let layer: CAMetalLayer
    }

    private init(device: any MTLDevice, queue: any MTLCommandQueue) {
        self.device = device
        commandQueue = queue
        // ⚠️ ONE CONTEXT FOR THE LIFE OF THE VIEW, ON THE VIEW'S OWN QUEUE —
        // `EditingRenderContext`'s rule. No intermediates cached: every frame is
        // a new picture.
        context = CIContext(mtlCommandQueue: queue, options: [.cacheIntermediates: false])
    }

    static func make() -> CaptureLiveRenderer? {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        return CaptureLiveRenderer(device: device, queue: queue)
    }

    func attach(_ layer: CAMetalLayer) {
        target.withLock { $0 = CAMetalLayerBox(layer: layer) }
    }

    func setDrawableSize(_ size: CGSize) {
        drawableSize.withLock { $0 = size }
    }

    var stats: (meanMilliseconds: Double, drawn: Int, dropped: Int) {
        timing.withLock { timing in
            let mean = timing.recent.isEmpty ? 0 : timing.recent.reduce(0, +) / Double(timing.recent.count)
            return (mean, timing.drawn, timing.dropped)
        }
    }

    func render(_ frame: CaptureFrame) {
        guard inFlight.compareExchange(expected: false, desired: true, ordering: .acquiring).exchanged else {
            timing.withLock { $0.dropped += 1 }
            return
        }
        let began = CACurrentMediaTime()
        let size = drawableSize.withLock { $0 }
        guard size.width > 0, let layer = target.withLock({ $0 })?.layer,
              let drawable = layer.nextDrawable(),
              let buffer = commandQueue.makeCommandBuffer()
        else {
            inFlight.store(false, ordering: .releasing)
            return
        }

        var image = CIImage(cvPixelBuffer: frame.pixelBuffer)
        if frame.isMirrored {
            image = image.transformed(by: CGAffineTransform(scaleX: -1, y: 1))
                .transformed(by: CGAffineTransform(translationX: image.extent.width, y: 0))
        }
        let seconds = frame.time.seconds.isFinite ? frame.time.seconds : 0
        image = FrameLookRenderer.apply(look.look, to: image, time: seconds)

        // Aspect FILL, centred — the plain preview layer's `.resizeAspectFill`,
        // so switching between the two paths does not move the picture.
        let extent = image.extent
        let scale = max(size.width / extent.width, size.height / extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let placed = scaled.transformed(by: CGAffineTransform(
            translationX: (size.width - scaled.extent.width) / 2 - scaled.extent.minX,
            y: (size.height - scaled.extent.height) / 2 - scaled.extent.minY
        ))

        context.render(
            placed, to: drawable.texture, commandBuffer: buffer,
            bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace
        )
        buffer.present(drawable)
        buffer.addCompletedHandler { [self] _ in
            let spent = (CACurrentMediaTime() - began) * 1000
            timing.withLock { timing in
                timing.recent.append(spent)
                if timing.recent.count > 120 { timing.recent.removeFirst(timing.recent.count - 120) }
                timing.drawn += 1
            }
            inFlight.store(false, ordering: .releasing)
        }
        buffer.commit()
    }
}
