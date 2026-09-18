import CoreImage
import MediaPlayback
import Metal
import QuartzCore
import Synchronization
import UIKit
import VideoToolbox

/// The live preview when it has to be DRAWN: every camera frame through Core
/// Image — the look, then an aspect fill — straight into a Metal drawable.
///
/// ⚠️ **THE LOOK IS THE EDITOR'S OWN GRAPH.** `FrameLookRenderer.apply` is what
/// the editor's canvas, the photo bake and the video compositor all draw a
/// `FrameLook` with, so the preview shows the look the editor will open on —
/// not an approximation of it.
///
/// ⚠️ **RENDERED ON A THREAD OF ITS OWN, WITH A STACK OF ITS OWN — AND THE
/// SIMULATOR IS WHY.** The first version encoded each frame on the queue that
/// delivered it, and the app died three times in twenty minutes on the
/// simulator with `EXC_BAD_ACCESS` — "Thread stack size exceeded" — inside
/// `CIContext.render(_:to:commandBuffer:…)`, 57 frames deep: Core Image binding
/// an IOSurface as a Metal texture goes through `MTLSimDriver`, which messages
/// the host GPU over XPC with buffers on the stack, and a dispatch worker's
/// 512KB stack does not hold it. A `Thread` states its stack size; this one has
/// 8MB. On a phone the driver is not in the path, and the thread still keeps
/// rendering off the capture queue, which AVFoundation asks to be left free.
///
/// ⚠️ **THE LATEST FRAME WINS, AND LATE FRAMES ARE DROPPED.** A frame waiting to
/// be drawn is replaced by a newer one, and while the GPU is still busy with
/// the last frame the next is skipped rather than queued — a slow look costs
/// frames, never latency; a preview that lags the hand is worse than one that
/// drops.
///
/// ⚠️ **MEASURED ON THE SIMULATED SOURCE** (iPhone 18 Pro simulator, iOS 27,
/// 720×1280 frames at 30 a second into a 1206×2144 drawable, `-camera-log-frames`,
/// each figure the mean of the last 120 frames, from hand-off to GPU completion):
/// 2.8ms with no look, 3.9ms in Noir with the filter row's cards redrawing twice a
/// second, and no frame dropped in 450 — a tenth of the 33ms a frame is given.
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

    /// A small square picture of `frame`, for the filter row's cards.
    ///
    /// ⚠️ **ON THE CPU, NOT THROUGH CORE IMAGE** — the renderer's stack note:
    /// a GPU render of an IOSurface from a cooperative thread is the path that
    /// overflowed a worker's stack on the simulator. VideoToolbox copies the
    /// buffer into a `CGImage` and UIKit scales it; at 56pt, twice a second,
    /// that is nothing.
    nonisolated static func snapshot(of frame: CaptureFrame, side: CGFloat) -> UIImage? {
        var picture: CGImage?
        VTCreateCGImageFromCVPixelBuffer(frame.pixelBuffer, options: nil, imageOut: &picture)
        guard let picture else { return nil }
        let width = CGFloat(picture.width)
        let height = CGFloat(picture.height)
        let scale = side / max(1, min(width, height))
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            let cg = context.cgContext
            if frame.isMirrored {
                cg.translateBy(x: side, y: 0)
                cg.scaleBy(x: -1, y: 1)
            }
            // `UIImage.draw` keeps the picture upright in UIKit's flipped context.
            UIImage(cgImage: picture).draw(in: CGRect(
                x: (side - width * scale) / 2, y: (side - height * scale) / 2,
                width: width * scale, height: height * scale
            ))
        }
    }

    /// Internal for tests and the frame-time log: the mean render time over the
    /// last frames, in milliseconds, and how many were drawn / dropped.
    var debugFrameStats: (meanMilliseconds: Double, drawn: Int, dropped: Int) {
        renderer?.stats ?? (0, 0, 0)
    }

    /// Internal for tests: the look every frame is being drawn in.
    var debugLook: FrameLook { renderer?.look.look ?? .neutral }
}

/// The Metal half of `CaptureLiveView`: frames are handed in from the source's
/// queue and drawn on the renderer's own thread.
final class CaptureLiveRenderer: Sendable {
    let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let context: CIContext
    let look = VideoLiveLook(.neutral)
    private let target = Mutex<CAMetalLayerBox?>(nil)
    private let drawableSize = Mutex(CGSize.zero)
    private let inFlight = Atomic(false)
    /// The frame waiting to be drawn — only ever the newest.
    private let pending = Mutex<CaptureFrame?>(nil)
    private let wake = DispatchSemaphore(value: 0)
    private let stopped = Atomic(false)
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
        let wake = self.wake
        let thread = Thread { [weak self] in
            while true {
                wake.wait()
                guard let self, !self.stopped.load(ordering: .acquiring) else { return }
                if let frame = self.pending.withLock({ frame -> CaptureFrame? in
                    defer { frame = nil }
                    return frame
                }) {
                    self.draw(frame)
                }
            }
        }
        thread.name = "capture.live-render"
        thread.stackSize = 8 << 20
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    deinit {
        stopped.store(true, ordering: .releasing)
        wake.signal()
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

    /// Hands `frame` to the render thread, replacing one not yet drawn.
    func render(_ frame: CaptureFrame) {
        let replaced = pending.withLock { waiting -> Bool in
            defer { waiting = frame }
            return waiting != nil
        }
        if replaced {
            timing.withLock { $0.dropped += 1 }
        } else {
            wake.signal()
        }
    }

    private func draw(_ frame: CaptureFrame) {
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
