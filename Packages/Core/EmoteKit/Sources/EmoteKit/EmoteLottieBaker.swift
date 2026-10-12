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
/// ⚠️ **EVERY COMMIT WAITS FOR THE MAIN THREAD TO SLEEP (#1001).** The tree
/// needs Core Animation transactions, and a commit, on ANY thread, lays out
/// every window in the process, not only the layers it changed:
/// `CA::Context::commit_transaction` walks all contexts and calls
/// `layout_and_display_if_needed` on each one's root. Committed at a moment
/// of the bake's choosing, the bake's transaction now and then landed while
/// the main thread was committing a window with layout in flight, and laid
/// that window out on `EmoteKit.bake`: AutoLayout threw ("modifications to the
/// layout engine must not be performed from a background thread") under the
/// commit in `EmoteFrameDrawer.init`, now and then in a full Feed test run. So
/// the bake commits only while the main thread sleeps in its run loop, after
/// its own commit and before its next turn (`EmoteMainPark`), when no window
/// has layout in flight. The main thread is held only if it wakes during a
/// commit, for what is left of it.
///
/// ⚠️ **A THREAD OF ITS OWN, NEVER A GCD WORKER.** A transaction belongs to a
/// THREAD, not to the code that opened it. On a GCD worker, which every queue
/// in the process shares, a transaction another queue left open would nest the
/// bake's, and the real commit would come later, outside the main thread's
/// sleep. And waiting for that sleep blocks the thread, which a shared worker
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
    /// This queue's commits and its waits for the main thread — a test seam,
    /// counted per queue so a test never reads another suite's bakes.
    var parks: EmoteParkCounters { thread.counters }

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

    private static let countersKey = "EmoteKit.bake.parks"

    /// Whether the caller runs on a bake thread.
    static var isCurrent: Bool { Thread.current.threadDictionary[marker] != nil }

    /// The calling bake thread's commit counters; nil off a bake thread.
    static var currentCounters: EmoteParkCounters? {
        Thread.current.threadDictionary[countersKey] as? EmoteParkCounters
    }

    /// This thread's commits, counted apart from every other thread's.
    let counters = EmoteParkCounters()

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
        let ownCounters = self.counters
        let thread = Thread {
            Thread.current.threadDictionary[Self.marker] = true
            Thread.current.threadDictionary[Self.countersKey] = ownCounters
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
/// there while the main thread sleeps, and the tree is released inside the
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
    /// asleep. The one step of a bake that waits for the main thread.
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

/// Core Animation commits made off the main thread only while the main thread
/// sleeps in its run loop (#1001, #1037).
///
/// A commit on any thread lays out EVERY window in the process (see
/// `EmoteBakeQueue`), so an off-main commit must not meet a window whose
/// layout the main thread has in flight. The main thread has none between the
/// LAST `beforeWaiting` observer of a turn (after Core Animation's commit and
/// UIKit's after-commit work) and the FIRST `afterWaiting` observer of the
/// next: it is asleep in the kernel, or about to be. Two observers mark that
/// stretch (`Gate`), and a bake commits only inside it.
///
/// ⚠️ **THE MAIN THREAD NEVER WAITS FOR THE BAKE THREAD TO BE SCHEDULED
/// (#1037).** The first version parked the main thread in an observer and
/// signalled the bake thread to commit. The main thread then stood still for
/// the bake thread's wake-up, not for the 0.07 ms commit: 14-70 ms a commit
/// on a loaded simulator, 100-800 ms beside CPU hogs. Now the bake thread
/// waits for the main thread to fall asleep and commits while it sleeps. The
/// main thread waits only when it wakes DURING a commit, for the rest of that
/// commit (the `afterWaiting` gate), capped at `longestWait`.
enum EmoteMainPark {
    /// The longest the main thread waits, on waking, for a commit in flight.
    /// A commit of a bake's detached tree takes a few tenths of a millisecond;
    /// this only bounds a commit that cannot finish while the main thread
    /// waits (a run loop nested inside a commit of its own, holding what the
    /// bake's needs).
    static let longestWait: TimeInterval = 0.25

    /// How long the bake thread waits for the main thread to fall asleep
    /// before it wakes it again (#1011). A main thread busy or in a private
    /// run-loop mode for longer only delays the commit; the bake thread never
    /// waits for good, and every bake after it still runs.
    static let retryInterval: TimeInterval = 0.5

    private static let cappedLogged = Atomic<Bool>(false)

    /// Commits the calling thread's transaction: at once on the main thread,
    /// and off it while the main thread sleeps.
    static func commit() {
        guard !Thread.isMainThread else {
            CATransaction.commit()
            return
        }
        whileParked { CATransaction.commit() }
    }

    /// Runs `body` on the calling (background) thread while the main thread
    /// sleeps. Blocks the caller until it does. Counted in the calling bake
    /// thread's `EmoteParkCounters`.
    ///
    /// ⚠️ **THE MAIN THREAD IS NOT WOKEN TO HURRY IT.** A main thread that is
    /// awake falls asleep at the end of its turn on its own. Woken while
    /// awake, it would fall asleep and wake again at once — and wake during
    /// the commit that slipped into that instant, and wait for it. It is woken
    /// only before it has ever been seen asleep (the observers are new) and
    /// when a wait runs out (`retryInterval`).
    ///
    /// ⚠️ **AT THE MAIN THREAD'S PRIORITY FROM THE WAIT TO THE END OF THE
    /// COMMIT.** A main thread that wakes during the commit waits for it, and a
    /// condition lends no priority. So the calling thread runs at
    /// user-interactive from the moment it waits (it must take the main
    /// thread's sleep before the sleep ends) until the commit is marked done,
    /// then is put back (a plain thread, not a GCD worker, so its QoS is its
    /// own).
    static func whileParked(_ body: () -> Void) {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let gate = Self.gate
        let counters = EmoteBakeThread.currentCounters ?? EmoteParkCounters()
        let previous = qos_class_self()
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
        defer { pthread_set_qos_class_self_np(previous, 0) }
        counters.waiting.add(1, ordering: .relaxed)
        gate.condition.lock()
        gate.waitingForSleep += 1
        var wake = !gate.everAsleep
        while !gate.mainAsleep || gate.committer != nil {
            if wake { CFRunLoopWakeUp(CFRunLoopGetMain()) }
            wake = !gate.condition.wait(until: Date().addingTimeInterval(retryInterval))
            if wake { counters.retried.add(1, ordering: .relaxed) }
        }
        gate.waitingForSleep -= 1
        gate.committer = counters
        gate.condition.unlock()
        counters.waiting.subtract(1, ordering: .relaxed)

        body()

        gate.condition.lock()
        gate.committer = nil
        gate.condition.broadcast()
        gate.condition.unlock()
        counters.committed.add(1, ordering: .relaxed)
    }

    /// The main thread's sleep as its run loop's observers see it, and the
    /// commit in flight. Every field is read and written under `condition`.
    private final class Gate: @unchecked Sendable {
        let condition = NSCondition()
        /// Between the last `beforeWaiting` observer and the next
        /// `afterWaiting` one.
        var mainAsleep = false
        /// The counters of the bake thread running `whileParked`'s body; nil
        /// when no commit is in flight.
        var committer: EmoteParkCounters?
        /// Bake threads waiting for the main thread to fall asleep.
        var waitingForSleep = 0
        /// Whether the main thread has been seen asleep since the observers
        /// were installed.
        var everAsleep = false
    }

    /// Installed once, the first time a bake commits, in the COMMON modes:
    /// the sleep mark after every other `beforeWaiting` observer, the gate
    /// before every other `afterWaiting` one. A turn costs each one a lock.
    private static let gate: Gate = {
        let installed = Gate()
        let falling = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, Int.max
        ) { _, _ in
            installed.condition.lock()
            installed.mainAsleep = true
            installed.everAsleep = true
            if installed.waitingForSleep > 0 { installed.condition.broadcast() }
            installed.condition.unlock()
        }
        let waking = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.afterWaiting.rawValue, true, Int.min
        ) { _, _ in
            installed.condition.lock()
            if let committer = installed.committer {
                let started = ContinuousClock.now
                let deadline = Date().addingTimeInterval(longestWait)
                while installed.committer != nil {
                    if !installed.condition.wait(until: deadline), installed.committer != nil {
                        noteCappedWait(committer)
                        break
                    }
                }
                committer.noteHold(ContinuousClock.now - started)
            }
            installed.mainAsleep = false
            installed.condition.unlock()
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), falling, .commonModes)
        CFRunLoopAddObserver(CFRunLoopGetMain(), waking, .commonModes)
        return installed
    }()

    private static func noteCappedWait(_ counters: EmoteParkCounters) {
        counters.capped.add(1, ordering: .relaxed)
        #if DEBUG
        if !cappedLogged.exchange(true, ordering: .relaxed) {
            print("[emote] the main thread waited its 250 ms cap for a bake's commit and went on; counted in EmoteParkCounters.cappedWaits (logged once)")
        }
        #endif
    }
}

/// What one bake thread's commits did (#1038) — a test seam, kept per thread
/// (`EmoteBakeThread.counters`, read through `EmoteBakeQueue.parks`) so a test
/// reads its own queue's numbers, never those of the bakes of a suite running
/// beside it.
final class EmoteParkCounters: Sendable {
    fileprivate let committed = Atomic<Int>(0)
    fileprivate let waiting = Atomic<Int>(0)
    fileprivate let retried = Atomic<Int>(0)
    fileprivate let capped = Atomic<Int>(0)
    private let heldTimes = Mutex(Holds())

    /// Commits made while the main thread slept.
    var commits: Int { committed.load(ordering: .relaxed) }
    /// Commits waiting for the main thread to fall asleep.
    var waitingCommits: Int { waiting.load(ordering: .relaxed) }
    /// Waits for the main thread's sleep that ran out after
    /// `EmoteMainPark.retryInterval` and woke it again.
    var retries: Int { retried.load(ordering: .relaxed) }
    /// Times the main thread stopped waiting after `EmoteMainPark.longestWait`
    /// while a commit was still running: the one path on which a bake's commit
    /// can meet the main thread's layout again (#1011). Logged once in DEBUG.
    var cappedWaits: Int { capped.load(ordering: .relaxed) }
    /// The main thread's time held by these commits: each hold from the
    /// moment it woke during one to the moment it went on (#1037) — what it
    /// could not spend on a touch. Only a main thread that wakes mid-commit is
    /// held.
    var holds: Holds { heldTimes.withLock { $0 } }

    struct Holds: Sendable {
        var count = 0
        var total = Duration.zero
        var longest = Duration.zero
    }

    fileprivate func noteHold(_ held: Duration) {
        heldTimes.withLock { holds in
            holds.count += 1
            holds.total += held
            holds.longest = max(holds.longest, held)
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
