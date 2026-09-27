import Lottie
import QuartzCore
import Synchronization

/// Bakes Lottie emotes into sprite sheets OFF THE MAIN THREAD, one at a time.
///
/// ## Why not the main thread
///
/// Some Noto frames cost tens of milliseconds to draw (🥶, 🤔, 🥹, 🥳, 🌞, 😩),
/// and a frame is never split. Drawn on the main thread — even only in idle
/// turns — every heavy frame was a turn in which a touch waited: the
/// fullscreen feed fell to ~7 fps for seconds while 🥶 baked. Here the main
/// thread only hands a job over and takes a finished sheet back.
///
/// ## Why this is safe
///
/// Lottie's main-thread engine is main-thread by NAME: its layers are plain
/// `CALayer`s (not main-actor-isolated), and the one place it checks the
/// thread is `display()`, which does nothing off the main thread. The baker
/// never goes through `display()`: it sets the frame and calls
/// `forceDisplayUpdate()`, which updates the same tree synchronously. Each job
/// owns its own layer tree, never attached to a window. The `LottieAnimation`
/// is shared, and Lottie declares it `Sendable` (an immutable model; the
/// per-frame state lives in the tree's nodes).
///
/// ⚠️ **ONE THING DOES REACH THE MAIN THREAD, AND IS WAITED OUT.** Building a
/// `LottieAnimationLayer` sets its first frame through a `CATransaction`
/// whose completion block — `forceDisplayUpdate()` on the new tree — Core
/// Animation runs on the MAIN thread. Drawing while it runs is a data race on
/// the tree's nodes (Thread Sanitizer names it) and, in pixels, a wrong frame
/// in nearly every bake that overlaps it: 😂's face orange (its inverted matte
/// cut nothing out). So a job builds the tree, lets the main thread run that
/// one redraw and commit it (`EmoteMainCommit`), and only then draws — on
/// the queue, alone. The main thread's share is that one small redraw.
///
/// ⚠️ **ONE JOB AT A TIME, AT UTILITY QoS.** A bake is invisible work: the
/// label shows the system glyph until its sheet lands. One serial queue keeps
/// the drawing to one core and below everything the user is waiting on.
final class EmoteBakeQueue: Sendable {
    static let shared = EmoteBakeQueue()

    private let queue = DispatchQueue(label: "EmoteKit.bake", qos: .utility)
    private let queued = Atomic<Int>(0)
    private let drawing = Atomic<Int>(0)

    /// Jobs queued or drawing — a test seam.
    var pendingJobs: Int { queued.load(ordering: .relaxed) }
    /// Jobs drawing their frames right now — a test seam.
    var drawingJobs: Int { drawing.load(ordering: .relaxed) }

    /// Draws `plan`'s frames of `animation` into one sheet. Nil when the
    /// calling task was cancelled first (the job stops at its next frame), or
    /// when the animation cannot be drawn.
    func bake(_ animation: LottieAnimation, plan: EmoteBakePlan) async -> EmoteBakeResult? {
        let cancellation = EmoteBakeCancellation()
        queued.add(1, ordering: .relaxed)
        defer { queued.subtract(1, ordering: .relaxed) }
        return await withTaskCancellationHandler {
            guard let session = await onQueue({ EmoteBakeSession(animation: animation, plan: plan) }) else {
                return nil
            }
            await session.waitForBirthRedraw()
            return await onQueue {
                self.drawing.add(1, ordering: .relaxed)
                defer { self.drawing.subtract(1, ordering: .relaxed) }
                return session.render(cancellation: cancellation)
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }
}

/// A finished sheet, and what drawing it cost (on the bake queue).
struct EmoteBakeResult: Sendable {
    let image: CGImage
    let drawingTime: Duration
}

/// Set from any thread when nobody waits for a job any more.
final class EmoteBakeCancellation: Sendable {
    private let flag = Atomic<Bool>(false)
    var isCancelled: Bool { flag.load(ordering: .relaxed) }
    func cancel() { flag.store(true, ordering: .relaxed) }
}

/// One bake's tree and sheet, handed between the bake queue and the main
/// thread — never used by both at once.
///
/// `@unchecked Sendable` because its layers are not: the queue builds it,
/// the main thread only reads one reference count while the queue waits, and
/// the queue draws after the main thread is done — each hand-off a
/// continuation, so each step happens-after the last.
final class EmoteBakeSession: @unchecked Sendable {
    private let drawer: EmoteFrameDrawer
    private let plan: EmoteBakePlan

    init?(animation: LottieAnimation, plan: EmoteBakePlan) {
        guard let drawer = EmoteFrameDrawer(animation: animation, side: plan.side) else { return nil }
        self.drawer = drawer
        self.plan = plan
    }

    /// Returns once the main thread has run the tree's birth redraw AND
    /// committed what it changed: the first main-run-loop commit after which
    /// the redraw is seen done, plus one more.
    @MainActor
    func waitForBirthRedraw() async {
        var ran = false
        // 600 commits: ten seconds of a live main thread. A main thread that
        // never turns stalls the bake; it never corrupts it.
        for _ in 0..<600 {
            await EmoteMainCommit.next()
            if ran { return }
            ran = drawer.birthRedrawHasRun()
        }
    }

    /// Draws every frame on the calling thread (the bake queue).
    func render(cancellation: EmoteBakeCancellation) -> EmoteBakeResult? {
        defer { drawer.close() }
        guard !cancellation.isCancelled,
              let sheet = EmoteCanvas.make(width: plan.pixelWidth, height: plan.pixelHeight)
        else { return nil }
        let clock = ContinuousClock()
        let started = clock.now
        drawer.open()
        for index in 0..<plan.frameCount {
            if cancellation.isCancelled { return nil }
            autoreleasepool {
                let frame = drawer.draw(atSeconds: plan.time(ofFrame: index))
                let origin = plan.origin(ofFrame: index)
                EmoteCanvas.copy(frame, into: sheet, x: origin.x, y: origin.y)
            }
        }
        guard let image = sheet.makeImage() else { return nil }
        return EmoteBakeResult(image: image, drawingTime: clock.now - started)
    }
}

/// The main run loop's Core Animation commits, as something to await.
@MainActor
enum EmoteMainCommit {
    /// Resumes right after the main run loop's next commit: a one-shot
    /// `beforeWaiting` observer in the COMMON modes (a scroll does not hold
    /// it back), ordered after Core Animation's own (2,000,000).
    static func next() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let observer = CFRunLoopObserverCreateWithHandler(
                kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, false, 2_000_100
            ) { _, _ in
                continuation.resume()
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }
}

/// A detached `.mainThread`-engine Lottie layer tree that draws one animation
/// at chosen times — on one thread at a time.
///
/// ⚠️ **THE MAIN THREAD ENGINE, DELIBERATELY.** It draws each frame into its
/// own layers, which `render(in:)` can capture; the Core Animation engine
/// expresses frames as `CAAnimation`s that an offscreen snapshot does not see
/// (StickerKit's `StickerFrameDrawer` measured this).
///
/// ⚠️ **BACKING STORES AT 4× THE CELL, NOT AT THE COMPOSITION'S SIZE.** Noto
/// is authored on a 1024-point canvas, and Lottie draws gradients, inverted
/// mattes and some shapes into backing stores of their own — at that size, at
/// `contentsScale` 1 (3 under a `LottieAnimationView` on a 3x screen: 3072²).
/// Filling those, not walking the layer tree, was most of a heavy frame. Every
/// layer is given `supersampling × cell / canvas` instead. Measured at 64 px,
/// off the main thread, Debug, iOS 27 simulator: 🥶 35.8 → 3.9 ms a frame,
/// 😂 20.2 → 4.5, 🤔 21.9 → 5.6, 🥹 18.3 → 2.9, 😩 19.7 → 4.0; light emoji
/// unchanged. The pixels move by at most 16/255 (42 on 🔥's one-pixel sparks)
/// — invisible at text size. At 2× they moved by up to 108.
///
/// ⚠️ **ONE TRANSACTION FOR THE WHOLE DRAWING, STORES DRAWN BY HAND.** A queue
/// thread has no run loop to commit an implicit transaction, and a commit
/// mid-bake is what would draw the backing stores — at a moment of Core
/// Animation's choosing. Instead the drawing runs in one explicit transaction
/// (`open()` … `close()`), and before each render every self-drawing layer is
/// displayed by hand, inputs first (an inverted matte renders another layer's
/// store from inside its own `display`).
final class EmoteFrameDrawer {
    /// How many times finer than the cell a backing store is drawn.
    static let supersampling: CGFloat = 4

    private var layer: LottieAnimationLayer
    private let root: CALayer
    private let animation: LottieAnimation
    private let side: Int
    /// Every layer of the tree, each after everything it may render.
    private let layers: [CALayer]
    /// The layers that draw their own backing store (Lottie's `draw(in:)`
    /// overrides: gradients, inverted mattes, shapes drawn in context, text),
    /// in the same order.
    private let selfDrawing: [CALayer]
    private let invertedMatteTotal: Int
    private let canvas: CGContext
    private var isOpen = false

    /// Nil when the tree cannot be driven frame by frame (no main-thread
    /// root, or a Lottie whose root no longer has `currentFrame`).
    init?(animation: LottieAnimation, side: Int) {
        guard let canvas = EmoteCanvas.make(width: side, height: side) else { return nil }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let made = LottieAnimationLayer(animation: animation, configuration: LottieConfiguration(renderingEngine: .mainThread))
        // The root's `currentFrame` is an `@NSManaged` Core Animation property:
        // set by key, it moves the tree without `LottieAnimationLayer`'s own
        // setter, which would schedule another main-thread redraw each time.
        guard let root = made.animationLayer, root.responds(to: NSSelectorFromString("setCurrentFrame:")) else {
            return nil
        }
        layer = made
        self.root = root
        self.animation = animation
        self.side = side
        self.canvas = canvas
        var layers: [CALayer] = []
        Self.collect(root, into: &layers)
        self.layers = layers
        selfDrawing = layers.filter(Self.drawsItself)
        invertedMatteTotal = layers.filter { Self.matteInput(of: $0) != nil }.count
        // Before the commit, so the main thread's birth redraw already draws
        // small stores.
        let scale = Self.supersampling * CGFloat(side) / max(animation.bounds.width, animation.bounds.height, 1)
        for layer in layers { layer.contentsScale = scale }
    }

    deinit { close() }

    /// Whether the redraw `LottieAnimationLayer` scheduled at birth has run:
    /// that block holds the layer strongly until it has.
    func birthRedrawHasRun() -> Bool {
        isKnownUniquelyReferenced(&layer)
    }

    /// Opens the transaction the frames are drawn in.
    func open() {
        guard !isOpen else { return }
        isOpen = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
    }

    /// Commits the drawing transaction, if open. Idempotent.
    func close() {
        guard isOpen else { return }
        isOpen = false
        CATransaction.commit()
    }

    /// Draws the frame at `seconds`, aspect-fit in a `side`-pixel square, and
    /// returns the canvas holding it — valid until the next call.
    func draw(atSeconds seconds: Double) -> CGContext {
        root.setValue(animation.frameTime(forTime: seconds), forKey: Self.frameKey)
        layer.forceDisplayUpdate()
        EmoteCanvas.clear(canvas)
        for store in selfDrawing {
            store.setNeedsDisplay()
            store.displayIfNeeded()
        }
        let bounds = animation.bounds
        let side = CGFloat(self.side)
        let scale = side / max(bounds.width, bounds.height, 1)
        canvas.saveGState()
        canvas.translateBy(x: (side - bounds.width * scale) / 2, y: (side - bounds.height * scale) / 2)
        canvas.scaleBy(x: scale, y: scale)
        root.render(in: canvas)
        canvas.restoreGState()
        return canvas
    }

    // MARK: - The tree

    private static let frameKey = "currentFrame"
    /// `InvertedMatteLayer.inputMatte`: the layer an inverted matte renders,
    /// held by that property alone (it is in no layer's `sublayers`).
    private static let matteInputKey = "inputMatte"

    private static func matteInput(of layer: CALayer) -> CALayer? {
        Mirror(reflecting: layer).children.first { $0.label == matteInputKey }?.value as? CALayer
    }

    /// Whether `layer` is one of Lottie's own layers that draws its contents
    /// (`draw(in:)` overridden) — never Core Animation's own classes, and
    /// never a layer holding an image it was given.
    private static func drawsItself(_ layer: CALayer) -> Bool {
        let type: AnyClass = Swift.type(of: layer)
        guard String(reflecting: type).hasPrefix("Lottie.") else { return false }
        let draw = #selector(CALayer.draw(in:))
        return class_getMethodImplementation(type, draw) != class_getMethodImplementation(CALayer.self, draw)
    }

    /// Post-order over sublayers, masks and inverted-matte inputs: every
    /// layer after everything it may render.
    private static func collect(_ layer: CALayer, into list: inout [CALayer]) {
        if let input = matteInput(of: layer) { collect(input, into: &list) }
        layer.sublayers?.forEach { collect($0, into: &list) }
        if let mask = layer.mask { collect(mask, into: &list) }
        list.append(layer)
    }

    // MARK: - Test seams

    var layerCount: Int { layers.count }
    var invertedMatteCount: Int { invertedMatteTotal }
    var selfDrawingCount: Int { selfDrawing.count }
    var backingStoreScales: Set<CGFloat> { Set(layers.map(\.contentsScale)) }
}

/// The bitmaps a bake draws into: BGRA, premultiplied (what Core Animation
/// uploads without a conversion pass), flipped to UIKit's orientation — origin
/// top-left, y down, which is what `layer.render` assumes and what makes
/// memory row 0 the TOP row `frameRects` expects.
enum EmoteCanvas {
    static func make(width: Int, height: Int) -> CGContext? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        return context
    }

    static func clear(_ context: CGContext) {
        guard let data = context.data else { return }
        memset(data, 0, context.bytesPerRow * context.height)
    }

    /// Copies `cell` into `sheet` with its top-left at pixel (`x`, `y`) from
    /// the sheet's top-left — exact bytes, no resampling.
    static func copy(_ cell: CGContext, into sheet: CGContext, x: Int, y: Int) {
        guard let source = cell.data, let target = sheet.data,
              x >= 0, y >= 0, x + cell.width <= sheet.width, y + cell.height <= sheet.height
        else { return }
        let rowBytes = cell.width * 4
        for row in 0..<cell.height {
            memcpy(target + (y + row) * sheet.bytesPerRow + x * 4, source + row * cell.bytesPerRow, rowBytes)
        }
    }
}

extension Duration {
    var milliseconds: Double {
        let parts = components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }
}
