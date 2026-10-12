import Foundation
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
/// the bake thread, alone. The main thread's share is that one small redraw,
/// and the two commits it waits out (below).
///
/// ⚠️ **ONE JOB AT A TIME, AT UTILITY QoS.** A bake is invisible work: the
/// label shows the system glyph until its sheet lands. One thread keeps the
/// drawing to one core and below everything the user is waiting on.
///
/// ⚠️ **EVERY COMMIT WAITS FOR THE MAIN THREAD TO PARK (#1001).** The tree
/// needs Core Animation transactions, and a commit, on ANY thread, lays out
/// every window in the process, not only the layers it changed:
/// `CA::Context::commit_transaction` walks all contexts and calls
/// `layout_and_display_if_needed` on each one's root. Committed at a moment
/// of the bake's choosing, the bake's transaction now and then landed while
/// the main thread was committing a window with layout in flight, and laid
/// that window out on `EmoteKit.bake`: AutoLayout threw ("modifications to the
/// layout engine must not be performed from a background thread") under the
/// commit in `EmoteFrameDrawer.init`, now and then in a full Feed test run. So
/// the bake commits only while the main thread waits in its run loop right
/// after its own commit (`EmoteMainPark`), when no window has layout in flight.
/// The main thread's share is the commit itself: 0.07 ms median, 0.3 ms at
/// the 90th percentile, 2.3 ms at worst (36 commits, Debug, iOS 27 simulator).
///
/// ⚠️ **A THREAD OF ITS OWN, NEVER A GCD WORKER.** A transaction belongs to a
/// THREAD, not to the code that opened it. On a GCD worker, which every queue
/// in the process shares, a transaction another queue left open would nest the
/// bake's, and the real commit would come later, unparked. And a parked
/// commit blocks its thread for a main-thread turn, which a shared worker
/// should not. On `EmoteBakeThread` nothing but a bake ever runs.
final class EmoteBakeQueue: Sendable {
    static let shared = EmoteBakeQueue()

    private let thread = EmoteBakeThread()
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
            guard let session = await run({ EmoteBakeSession(animation: animation, plan: plan) }) else {
                return nil
            }
            await session.waitForBirthRedraw()
            return await run {
                self.drawing.add(1, ordering: .relaxed)
                let result = session.render(cancellation: cancellation)
                self.drawing.subtract(1, ordering: .relaxed)
                session.finish()
                return result
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// Runs `body` on the bake thread, after every job handed over before it.
    func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            thread.enqueue { continuation.resume(returning: body()) }
        }
    }
}

/// A thread that runs the jobs handed to it one at a time, in order — and
/// nothing else, ever (see `EmoteBakeQueue`). It ends once its owner is gone
/// and its last job has run.
final class EmoteBakeThread: Sendable {
    private static let marker = "EmoteKit.bake"

    /// Whether the caller runs on a bake thread.
    static var isCurrent: Bool { Thread.current.threadDictionary[marker] != nil }

    /// What the thread and its owner share — never the owner itself, so the
    /// owner can go.
    private final class Inbox: Sendable {
        enum Job {
            case run(@Sendable () -> Void)
            case stop
        }

        private let jobs = Mutex<[Job]>([])
        private let ready = DispatchSemaphore(value: 0)

        func post(_ job: Job) {
            jobs.withLock { $0.append(job) }
            ready.signal()
        }

        func next() -> Job {
            ready.wait()
            return jobs.withLock { $0.removeFirst() }
        }
    }

    private let inbox = Inbox()

    init() {
        let shared = self.inbox
        let thread = Thread {
            Thread.current.threadDictionary[Self.marker] = true
            while case .run(let job) = shared.next() {
                autoreleasepool { job() }
            }
        }
        thread.name = Self.marker
        thread.qualityOfService = .utility
        thread.start()
    }

    deinit {
        inbox.post(.stop)
    }

    func enqueue(_ job: @escaping @Sendable () -> Void) {
        inbox.post(.run(job))
    }
}

/// A finished sheet, and what drawing it cost (on the bake thread).
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

/// One bake's tree and sheet, handed between the bake thread and the main
/// thread — never used by both at once.
///
/// `@unchecked Sendable` because its layers are not: the bake thread builds
/// it, the main thread only reads one reference count while the bake thread
/// waits, and the bake thread draws after the main thread is done — each
/// hand-off a continuation, so each step happens-after the last.
///
/// Built, drawn and let go ON THE BAKE THREAD (`EmoteBakeThread`): every
/// Core Animation transaction the tree needs is opened there and committed
/// there while the main thread is parked, and the tree is released inside the
/// last one, so no other thread is left holding a transaction of the bake's.
final class EmoteBakeSession: @unchecked Sendable {
    private let drawer: EmoteFrameDrawer
    private let plan: EmoteBakePlan

    init?(animation: LottieAnimation, plan: EmoteBakePlan) {
        assert(EmoteBakeThread.isCurrent, "a bake session is built on the bake thread")
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

    /// Draws every frame on the calling thread (the bake thread). Called
    /// once, and followed by `finish()` whatever it returns.
    func render(cancellation: EmoteBakeCancellation) -> EmoteBakeResult? {
        assert(EmoteBakeThread.isCurrent, "a bake draws on the bake thread")
        drawer.open()
        guard !cancellation.isCancelled,
              let sheet = EmoteCanvas.make(width: plan.pixelWidth, height: plan.pixelHeight)
        else { return nil }
        let clock = ContinuousClock()
        let started = clock.now
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

    /// Lets the tree go and commits the drawing — while the main thread is
    /// parked. The one step of a bake that waits for the main thread.
    func finish() {
        assert(EmoteBakeThread.isCurrent, "a bake finishes on the bake thread")
        drawer.close()
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

/// Core Animation commits made off the main thread while the main thread
/// waits (#1001).
///
/// A commit on any thread lays out EVERY window in the process (see
/// `EmoteBakeQueue`), so an off-main commit must not meet a window whose
/// layout the main thread has in flight. The main thread is parked where it
/// has none: in its run loop, right after its own commit (the same observer
/// slot as `EmoteMainCommit`). There it waits, without running anything, while
/// the bake thread commits, then goes on.
enum EmoteMainPark {
    /// The longest the main thread waits for one commit. A commit of a
    /// bake's detached tree takes a few tenths of a millisecond; this only bounds
    /// a commit that cannot finish while the main thread waits (a run loop
    /// nested inside a commit of its own, holding what the bake's needs).
    static let longestWait = DispatchTimeInterval.milliseconds(250)

    /// How long the bake thread waits for the main thread to park before it
    /// asks again (#1011): the observer is withdrawn, added anew and the main
    /// thread woken. A main thread busy or in a private run-loop mode for
    /// longer only delays the commit; the bake thread never waits on one
    /// request for good, and every bake after it still runs.
    static let retryInterval = DispatchTimeInterval.milliseconds(500)

    private static let parked = Atomic<Int>(0)
    private static let waiting = Atomic<Int>(0)
    private static let retried = Atomic<Int>(0)
    private static let capped = Atomic<Int>(0)
    private static let cappedLogged = Atomic<Bool>(false)

    /// Commits made while the main thread was parked — a test seam.
    static var parkedCommits: Int { parked.load(ordering: .relaxed) }
    /// Threads waiting for the main thread to park — a test seam.
    static var waitingCommits: Int { waiting.load(ordering: .relaxed) }
    /// Requests withdrawn after `retryInterval` and made again — a test seam.
    static var retries: Int { retried.load(ordering: .relaxed) }
    /// Times the main thread stopped waiting after `longestWait` while a
    /// commit was still running: the one path on which a bake's commit can
    /// meet the main thread's layout again (#1011). Logged once in DEBUG.
    static var cappedWaits: Int { capped.load(ordering: .relaxed) }

    /// Commits the calling thread's transaction: at once on the main thread,
    /// and off it once the main thread is parked.
    static func commit() {
        guard !Thread.isMainThread else {
            CATransaction.commit()
            return
        }
        whileParked { CATransaction.commit() }
    }

    /// One request to park the main thread, shared by the observer and the
    /// thread that made it. Its state decides, once, which of them wins a
    /// race between the observer firing and the request being withdrawn.
    private final class Request: Sendable {
        static let pending = 0, parked = 1, withdrawn = 2
        let state = Atomic<Int>(Request.pending)
        let arrived = DispatchSemaphore(value: 0)
        let released = DispatchSemaphore(value: 0)
    }

    /// Runs `body` on the calling (background) thread while the main thread
    /// is parked. Blocks the caller until the main thread gets there.
    ///
    /// ⚠️ **AT THE MAIN THREAD'S PRIORITY MEANWHILE.** A semaphore lends no
    /// priority: a utility thread the main thread waits on could sit behind
    /// every busier thread while the main thread stands still. The calling
    /// thread is raised to user-interactive for the wait and the commit, then
    /// put back (a plain thread, not a GCD worker, so its QoS is its own).
    ///
    /// ⚠️ **A REQUEST IS WITHDRAWN ONLY IF THE MAIN THREAD HAS NOT TAKEN
    /// IT.** The observer and the timed-out caller race; each claims the
    /// request with one compare-and-swap. A main thread that claimed it first
    /// is parked (or about to be), so the caller commits; one that comes too
    /// late finds it withdrawn and goes on at once.
    static func whileParked(_ body: () -> Void) {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let previous = qos_class_self()
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
        defer { pthread_set_qos_class_self_np(previous, 0) }
        waiting.add(1, ordering: .relaxed)
        var request = Request()
        while !park(request) {
            retried.add(1, ordering: .relaxed)
            request = Request()
        }
        waiting.subtract(1, ordering: .relaxed)
        body()
        parked.add(1, ordering: .relaxed)
        request.released.signal()
    }

    /// Asks the main thread to park for `request`. True once it is parked;
    /// false when `retryInterval` passed first and the request was withdrawn.
    private static func park(_ request: Request) -> Bool {
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, false, 2_000_100
        ) { _, _ in
            guard request.state.compareExchange(
                expected: Request.pending, desired: Request.parked, ordering: .acquiringAndReleasing
            ).exchanged else { return }
            request.arrived.signal()
            if request.released.wait(timeout: .now() + longestWait) == .timedOut {
                noteCappedWait()
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        CFRunLoopWakeUp(CFRunLoopGetMain())
        if request.arrived.wait(timeout: .now() + retryInterval) == .success { return true }
        if request.state.compareExchange(
            expected: Request.pending, desired: Request.withdrawn, ordering: .acquiringAndReleasing
        ).exchanged {
            CFRunLoopObserverInvalidate(observer)
            return false
        }
        // The main thread claimed it as the wait ran out: it is parking.
        request.arrived.wait()
        return true
    }

    private static func noteCappedWait() {
        capped.add(1, ordering: .relaxed)
        #if DEBUG
        if !cappedLogged.exchange(true, ordering: .relaxed) {
            print("[emote] the main thread waited its 250 ms cap for a bake's commit and went on; counted in EmoteMainPark.cappedWaits (logged once)")
        }
        #endif
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
/// ⚠️ **ONE TRANSACTION FOR THE WHOLE DRAWING, STORES DRAWN BY HAND.** A
/// bake thread has no run loop to commit an implicit transaction, and a
/// commit mid-bake is what would draw the backing stores — at a moment of
/// Core Animation's choosing. Instead the drawing runs in one explicit
/// transaction (`open()` … `close()`), and before each render every
/// self-drawing layer is displayed by hand, inputs first (an inverted matte
/// renders another layer's store from inside its own `display`). `close()`
/// lets the tree go INSIDE that transaction, so tearing it down opens no
/// implicit one on whatever thread drops the drawer last.
///
/// Used on the bake thread (`EmoteBakeThread`), or on the main thread by
/// tests — never on a thread other code shares.
final class EmoteFrameDrawer {
    /// How many times finer than the cell a backing store is drawn.
    static let supersampling: CGFloat = 4

    /// The detached tree: until `close()`.
    private struct Tree {
        var layer: LottieAnimationLayer
        let root: CALayer
        /// Every layer of the tree, each after everything it may render.
        let layers: [CALayer]
        /// The layers that draw their own backing store (Lottie's `draw(in:)`
        /// overrides: gradients, inverted mattes, shapes drawn in context,
        /// text), in the same order.
        let selfDrawing: [CALayer]
    }

    private var tree: Tree?
    private let animation: LottieAnimation
    private let side: Int
    private let invertedMatteTotal: Int
    private let canvas: CGContext
    private var isOpen = false

    /// Nil when the tree cannot be driven frame by frame (no main-thread
    /// root, or a Lottie whose root no longer has `currentFrame`).
    init?(animation: LottieAnimation, side: Int) {
        assert(EmoteBakeThread.isCurrent || Thread.isMainThread, "a frame drawer runs on the bake thread or the main thread")
        guard let canvas = EmoteCanvas.make(width: side, height: side) else { return nil }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { EmoteMainPark.commit() }
        let made = LottieAnimationLayer(animation: animation, configuration: LottieConfiguration(renderingEngine: .mainThread))
        // The root's `currentFrame` is an `@NSManaged` Core Animation property:
        // set by key, it moves the tree without `LottieAnimationLayer`'s own
        // setter, which would schedule another main-thread redraw each time.
        guard let root = made.animationLayer, root.responds(to: NSSelectorFromString("setCurrentFrame:")) else {
            return nil
        }
        var layers: [CALayer] = []
        Self.collect(root, into: &layers)
        tree = Tree(layer: made, root: root, layers: layers, selfDrawing: layers.filter(Self.drawsItself))
        self.animation = animation
        self.side = side
        self.canvas = canvas
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
        guard tree != nil else { return true }
        return isKnownUniquelyReferenced(&tree!.layer)
    }

    /// Opens the transaction the frames are drawn in.
    func open() {
        guard !isOpen, tree != nil else { return }
        isOpen = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
    }

    /// Lets the tree go and commits the drawing transaction, if open. The
    /// drawer draws nothing after. Idempotent.
    func close() {
        guard isOpen else { return }
        isOpen = false
        tree = nil
        EmoteMainPark.commit()
    }

    /// Draws the frame at `seconds`, aspect-fit in a `side`-pixel square, and
    /// returns the canvas holding it — valid until the next call; blank once
    /// the drawer is closed.
    func draw(atSeconds seconds: Double) -> CGContext {
        EmoteCanvas.clear(canvas)
        guard let tree else { return canvas }
        let root = tree.root
        root.setValue(animation.frameTime(forTime: seconds), forKey: Self.frameKey)
        tree.layer.forceDisplayUpdate()
        for store in tree.selfDrawing {
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

    var layerCount: Int { tree?.layers.count ?? 0 }
    var invertedMatteCount: Int { invertedMatteTotal }
    var selfDrawingCount: Int { tree?.selfDrawing.count ?? 0 }
    var backingStoreScales: Set<CGFloat> { Set(tree?.layers.map(\.contentsScale) ?? []) }
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
