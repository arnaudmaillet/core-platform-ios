import Lottie
import MediaCore
import UIKit

/// One Lottie being rasterised into ONE sprite sheet, a frame at a time.
///
/// ⚠️ **ONE CONTEXT, NO PER-FRAME IMAGES.** Every frame is drawn straight into
/// its cell of a single bitmap context, which becomes the sheet with one
/// `makeImage()`. A bake allocates the sheet and nothing else of its size.
///
/// ⚠️ **A FRAME COSTS WHAT THE ANIMATION HOLDS, NOT WHAT IT MEASURES.**
/// Measured on the iOS 27 simulator: 😂 and 😭 cost ~10 ms a frame at 32, 64
/// and 128 px alike, 👍 ~5 ms, ❤️ under 1 ms — the time is Lottie walking its
/// layer tree, and pixels are nearly free. That is why a bake never runs on a
/// schedule of its own: `EmoteIdleBaker` draws frames only while the main run
/// loop is idle.
@MainActor
final class EmoteBakeJob {
    let plan: EmoteBakePlan
    private let context: CGContext
    private let drawer: EmoteFrameDrawer
    private(set) var drawnFrames = 0
    /// Time spent drawing, summed over frames — the main-thread cost.
    private(set) var drawingTime = Duration.zero
    /// Idle turns this job took.
    private(set) var turns = 0

    var isFinished: Bool { drawnFrames >= plan.frameCount }

    init?(animation: LottieAnimation, plan: EmoteBakePlan) {
        guard let context = CGContext(
            data: nil, width: plan.pixelWidth, height: plan.pixelHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            // BGRA, premultiplied: the layout Core Animation uploads without a
            // conversion pass.
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        // UIKit's orientation: origin top-left, y down — what `layer.render`
        // assumes, and what makes row 0 the TOP row `frameRects` expects.
        context.translateBy(x: 0, y: CGFloat(plan.pixelHeight))
        context.scaleBy(x: 1, y: -1)
        self.plan = plan
        self.context = context
        self.drawer = EmoteFrameDrawer(animation: animation, side: plan.side)
    }

    /// Draws frames until `budget` is spent — always at least one.
    func drawFrames(budget: Duration) {
        guard !isFinished else { return }
        let clock = ContinuousClock()
        let started = clock.now
        turns += 1
        repeat {
            let origin = plan.origin(ofFrame: drawnFrames)
            context.saveGState()
            context.translateBy(x: CGFloat(origin.x), y: CGFloat(origin.y))
            drawer.draw(atSeconds: plan.time(ofFrame: drawnFrames), in: context)
            context.restoreGState()
            drawnFrames += 1
        } while !isFinished && clock.now - started < budget
        drawingTime += clock.now - started
    }

    /// The finished sheet.
    func makeArt() -> AnimatedIconArt? {
        guard isFinished, let image = context.makeImage() else { return nil }
        return .sheet(AnimatedIconSheet(
            sheet: UIImage(cgImage: image), frameCount: plan.frameCount, columns: plan.columns,
            frameDuration: plan.frameDuration, gutterPX: plan.gutter
        ))
    }
}

/// Runs bake jobs ONLY WHILE THE MAIN RUN LOOP IS IDLE — and never while a
/// finger is down or a scroll view is decelerating.
///
/// A run-loop observer on `.beforeWaiting`, registered for the DEFAULT mode
/// alone and ordered after Core Animation's commit: it fires only when the main
/// thread has finished a turn, committed its frame and is about to sleep with
/// nothing left to do. Tracking and deceleration run the loop in
/// `UITrackingRunLoopMode`, where this observer does not exist, so a scroll
/// never waits on a bake. Each idle turn draws for at most `budget` (one frame
/// at least) and wakes the loop again if work remains, so a touch arriving
/// mid-bake is handled after one frame, not after the bake.
@MainActor
final class EmoteIdleBaker {
    static let shared = EmoteIdleBaker()

    /// How long one idle turn may draw — half a 60 Hz frame. A single frame
    /// can exceed it; it is never split.
    static let budget = Duration.milliseconds(8)

    /// One queued job; also the handle that cancels it.
    @MainActor
    final class Entry {
        let job: EmoteBakeJob
        fileprivate var completion: (@MainActor (Bool) -> Void)?
        init(job: EmoteBakeJob, completion: @escaping @MainActor (Bool) -> Void) {
            self.job = job
            self.completion = completion
        }

        fileprivate func finish(_ finished: Bool) {
            let completion = self.completion
            self.completion = nil
            completion?(finished)
        }
    }

    private var queue: [Entry] = []
    private var observer: CFRunLoopObserver?

    /// Draws `job` to its end over idle turns. False when the calling task was
    /// cancelled first; the job is then dropped where it stood.
    func run(_ job: EmoteBakeJob) async -> Bool {
        let handle = EntryHandle()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                    return
                }
                handle.entry = enqueue(job) { continuation.resume(returning: $0) }
            }
        } onCancel: {
            Task { @MainActor in handle.entry.map { EmoteIdleBaker.shared.drop($0) } }
        }
    }

    /// Queues `job`; `completion` runs once, with true when the job finished
    /// and false when it was dropped.
    @discardableResult
    func enqueue(_ job: EmoteBakeJob, completion: @escaping @MainActor (Bool) -> Void) -> Entry {
        let entry = Entry(job: job, completion: completion)
        queue.append(entry)
        installObserverIfNeeded()
        CFRunLoopWakeUp(CFRunLoopGetMain())
        return entry
    }

    func drop(_ entry: Entry) {
        guard let index = queue.firstIndex(where: { $0 === entry }) else { return }
        queue.remove(at: index).finish(false)
    }

    private func installObserverIfNeeded() {
        guard observer == nil else { return }
        // After Core Animation's commit observer (2,000,000): the turn's frame
        // is already on its way to the render server when drawing starts.
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, 2_000_100
        ) { _, _ in
            MainActor.assumeIsolated { EmoteIdleBaker.shared.idleTurn() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .defaultMode)
        self.observer = observer
    }

    private func idleTurn() {
        guard let entry = queue.first else { return }
        entry.job.drawFrames(budget: Self.budget)
        if entry.job.isFinished {
            queue.removeFirst()
            entry.finish(true)
        }
        if !queue.isEmpty {
            // Come round again: the loop was about to sleep.
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }

    var pendingJobs: Int { queue.count }
}

/// Carries the queued entry from `run`'s body to its cancellation handler.
@MainActor
private final class EntryHandle {
    var entry: EmoteIdleBaker.Entry?
}

/// A `.mainThread` Lottie view that draws one animation at chosen times.
///
/// ⚠️ **THE MAIN THREAD ENGINE, DELIBERATELY, AND ONLY FOR DRAWING.** It draws
/// each frame into its own layers, which `render(in:)` can capture; the Core
/// Animation engine expresses frames as `CAAnimation`s that an offscreen
/// snapshot does not see (StickerKit's `StickerFrameDrawer` measured this).
///
/// ⚠️ **NO `forceDisplayUpdate()`.** Setting the time and displaying what is
/// dirty draws the same pixels (measured: 20 frames of 😂 and 😭 identical
/// byte for byte) in ~10 ms a frame instead of ~18.
@MainActor
final class EmoteFrameDrawer {
    private let view: LottieAnimationView

    init(animation: LottieAnimation, side: Int) {
        view = LottieAnimationView(
            animation: animation,
            configuration: LottieConfiguration(renderingEngine: .mainThread)
        )
        view.contentMode = .scaleAspectFit
        // Points, drawn into a context that is 1 pixel a point: the view's size
        // IS the cell's size in pixels.
        view.frame = CGRect(x: 0, y: 0, width: side, height: side)
        view.layoutIfNeeded()
    }

    func draw(atSeconds seconds: Double, in context: CGContext) {
        view.currentTime = seconds
        view.layer.displayIfNeeded()
        view.layer.sublayers?.forEach { $0.displayIfNeeded() }
        view.layer.render(in: context)
    }
}

extension Duration {
    var milliseconds: Double {
        let parts = components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }
}
