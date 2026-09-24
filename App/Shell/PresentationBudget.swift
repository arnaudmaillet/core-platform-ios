import Darwin
import MachO
import ObjectiveC
import UIKit

// ⚠️ THE WHOLE FILE: a DEBUG harness, installed only under `-presentation-budget`.
#if DEBUG

/// `-presentation-budget` — times the main-thread run-loop turn that brings a
/// screen on, and names what it spent the time in.
///
/// # The clause it measures
///
/// `dev/PRESENTATION_CHARTER.md` P2: a screen's construction (init, `viewDidLoad`,
/// first layout) costs under 8 ms on the slowest supported device, because the
/// push starts in the same run-loop turn the screen is built in and every
/// millisecond spent there is a millisecond the animation starts late. A
/// skeleton cannot fix that — only moving the work can — so the instrument
/// reports the WORK, not the wait.
///
/// # What is measured, and why a run-loop turn
///
/// Timing `viewDidLoad` alone misses the init (a Swift init is not a method the
/// runtime can hook), the `loadView`, the first layout of the whole subtree
/// (children lay out after their parent's `layoutSubviews` returns), and the
/// builder work that precedes the push. All of it happens in ONE run-loop turn,
/// so the turn is the unit: an observer marks the turn's start
/// (`afterWaiting`) and its end (`beforeWaiting`, ordered after Core
/// Animation's commit), and every `viewDidLoad` and every controller root
/// view's first `layoutSubviews` inside the turn is recorded as that turn's
/// screen events. A turn with screen events over the budget is a P2 failure.
///
/// Two finer witnesses ride along so the report names a culprit, not a screen:
///
///   - every `viewDidLoad` override in the app's own classes is timed by name
///     (the class list is walked once at install and each override wrapped, so
///     a subclass chain reports its outermost class once);
///   - once a turn runs past the budget, a watchdog thread samples the main
///     thread's stack every 2 ms until the turn ends, walks the frame pointers,
///     and reports the app's own frames that appeared most often.
///
/// # Arguments
///
///   - `-presentation-budget`           install; log to console + `Documents/presentation-budget.log`
///   - `-presentation-budget-ms N`      the budget (default 8)
///   - `-presentation-budget-trap`      a screen turn over budget traps (what the sweep test runs with)
///   - `-presentation-budget-grace N`   ms added after the launch before judging (default 0)
///
/// A probe element on the key window (`budget;turns=…;screens=…;over=…;worst=…`)
/// gives a UI test the denominator: how many screen turns were measured, how
/// many were over, and the worst one.
@MainActor
enum PresentationBudget {
    private static var isInstalled = false
    nonisolated(unsafe) private static var budgetMs: Double = 8
    private static var traps = false
    private static var graceMs: Double = 0
    /// The launch is exempt: the turn that builds the tab shell and every
    /// screen turn that follows it back to back (the tab roots, a
    /// `-select-tab`). The first turn with no screen event ends the launch;
    /// a route that lands later — a push after a fetch, a tap — is judged.
    /// `-presentation-budget-grace` adds milliseconds after that point.
    private static var judgeFrom: CFAbsoluteTime = .greatestFiniteMagnitude
    private static var shellSeen = false
    private static var installedAt: CFAbsoluteTime = 0
    private static var sink: FileHandle?

    // Per-turn state, main thread only.
    private static var turnStart: CFAbsoluteTime = 0
    private static var inTurn = false
    private static var turnEvents: [String] = []
    private static var turnLoads: [(name: String, ms: Double)] = []
    private static var loadStack: [(instance: ObjectIdentifier, start: CFAbsoluteTime)] = []

    // Totals, main thread only.
    private static var turns = 0
    private static var screenTurns = 0
    private static var overTurns = 0
    private static var worst: (name: String, ms: Double) = ("", 0)
    private static var worstHot: [String] = []
    private static let probe = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))

    // The sampler's view of the turn, shared across threads behind a lock.
    private static let samplerLock = NSLock()
    nonisolated(unsafe) private static var samplerTurnStart: CFAbsoluteTime = 0
    nonisolated(unsafe) private static var samplerArmed = false
    nonisolated(unsafe) private static var samples: [[UInt]] = []
    nonisolated(unsafe) private static var mainMachThread: mach_port_t = 0
    nonisolated(unsafe) private static var mainStackTop: UInt = 0
    nonisolated(unsafe) private static var mainStackBottom: UInt = 0

    static func installIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-presentation-budget"), !isInstalled else { return }
        isInstalled = true
        if let index = arguments.firstIndex(of: "-presentation-budget-ms"), index + 1 < arguments.count,
           let value = Double(arguments[index + 1]) {
            budgetMs = value
        }
        if let index = arguments.firstIndex(of: "-presentation-budget-grace"), index + 1 < arguments.count,
           let value = Double(arguments[index + 1]) {
            graceMs = value
        }
        traps = arguments.contains("-presentation-budget-trap")
        installedAt = CFAbsoluteTimeGetCurrent()

        let url = URL.documentsDirectory.appendingPathComponent("presentation-budget.log")
        try? Data().write(to: url)
        sink = try? FileHandle(forWritingTo: url)

        installTurnObserver()
        let wrapped = wrapViewDidLoadOverrides()
        swizzleBaseViewDidLoad()
        swizzleLayoutSubviews()
        startSampler()

        probe.isAccessibilityElement = true
        probe.accessibilityIdentifier = "budget;turns=0;screens=0;over=0;worst=none:0"
        probe.isUserInteractionEnabled = false
        publishProbe()

        emit("[budget] START budget=\(budgetMs)ms trap=\(traps) grace=\(Int(graceMs))ms after the launch"
             + " wrappedViewDidLoad=\(wrapped) sink=\(url.path)")
    }

    // MARK: - The turn

    /// How many run loops are nested inside the outermost one. The outer
    /// loop entered before this observer existed, so 0 is the outer level
    /// and anything above it is a nested `CFRunLoopRunInMode` (a synchronous
    /// XPC wait, a modal spin). A nested loop's wake-ups and sleeps are NOT
    /// turn boundaries: the outer turn is still running around them.
    private static var nesting = 0

    private static func installTurnObserver() {
        // `afterWaiting` first of all observers; `beforeWaiting` after Core
        // Animation's commit (order 2_000_000) so the turn includes the commit
        // that flushes the layout the screen asked for.
        let starter = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min
        ) { _, _ in MainActor.assumeIsolated { if nesting == 0 { beginTurn() } } }
        let ender = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, 2_100_000
        ) { _, _ in MainActor.assumeIsolated { if nesting == 0 { endTurn() } } }
        let depth = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity.entry.rawValue | CFRunLoopActivity.exit.rawValue,
            true, CFIndex.min
        ) { _, activity in
            MainActor.assumeIsolated {
                if activity == .entry { nesting += 1 } else { nesting = max(0, nesting - 1) }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), starter, .commonModes)
        CFRunLoopAddObserver(CFRunLoopGetMain(), ender, .commonModes)
        CFRunLoopAddObserver(CFRunLoopGetMain(), depth, .commonModes)
    }

    private static func beginTurn() {
        guard !inTurn else { return }
        inTurn = true
        turnStart = CFAbsoluteTimeGetCurrent()
        turnEvents.removeAll(keepingCapacity: true)
        turnLoads.removeAll(keepingCapacity: true)
        samplerLock.lock()
        samplerTurnStart = turnStart
        samplerArmed = turnStart >= judgeFrom
        samples.removeAll(keepingCapacity: true)
        samplerLock.unlock()
    }

    private static func endTurn() {
        guard inTurn else { return }
        inTurn = false
        let elapsed = (CFAbsoluteTimeGetCurrent() - turnStart) * 1000
        samplerLock.lock()
        samplerArmed = false
        let taken = samples
        samples.removeAll(keepingCapacity: true)
        samplerLock.unlock()
        turns += 1
        if judgeFrom == .greatestFiniteMagnitude {
            if !shellSeen, turnEvents.contains("load:ShellTabBarController") {
                shellSeen = true
                emit("[budget] launch turn=\(format(elapsed))ms (the tab shell; exempt) events=\(turnEvents.count)")
                return
            }
            if shellSeen, turnEvents.isEmpty {
                judgeFrom = CFAbsoluteTimeGetCurrent() + graceMs / 1000
                emit("[budget] launch over: first quiet turn after the shell; judging from here"
                     + (graceMs > 0 ? " + \(Int(graceMs))ms" : ""))
                return
            }
            if !shellSeen, CFAbsoluteTimeGetCurrent() - installedAt > 10 {
                judgeFrom = CFAbsoluteTimeGetCurrent()
                emit("[budget] no tab shell 10s after install (a login screen?) — judging from here")
            } else {
                if !turnEvents.isEmpty {
                    emit("[budget] launch turn=\(format(elapsed))ms (exempt) events=[\(turnEvents.prefix(6).joined(separator: ", "))\(turnEvents.count > 6 ? ", …" : "")]")
                }
                return
            }
        }
        guard turnStart >= judgeFrom else {
            if !turnEvents.isEmpty {
                emit("[budget] grace turn=\(format(elapsed))ms (exempt) events=[\(turnEvents.prefix(6).joined(separator: ", "))\(turnEvents.count > 6 ? ", …" : "")]")
            }
            return
        }

        let isScreen = !turnEvents.isEmpty
        if isScreen { screenTurns += 1 }
        let over = elapsed > budgetMs
        // Unattributed slow turns (a scroll, a decode) are worth a line at
        // twice the budget; screen turns at the budget itself.
        guard (isScreen && (over || !turnLoads.isEmpty)) || elapsed > budgetMs * 2 else { return }

        var line = "[budget] turn=\(format(elapsed))ms"
        line += over ? " OVER" : " ok"
        if !isScreen { line += " unattributed" }
        if !turnEvents.isEmpty {
            let shown = turnEvents.prefix(12).joined(separator: ", ")
            let more = turnEvents.count > 12 ? ", +\(turnEvents.count - 12) more" : ""
            line += " events=[\(shown)\(more)]"
        }
        if !turnLoads.isEmpty {
            let loads = turnLoads.map { "\($0.name)=\(format($0.ms))ms" }
            line += " viewDidLoad=[\(loads.joined(separator: ", "))]"
        }
        emit(line)

        if isScreen && over {
            overTurns += 1
            let name = turnEvents.first ?? "?"
            let hot = hottestFrames(in: taken)
            if elapsed > worst.ms {
                worst = (name, elapsed)
                worstHot = hot.prefix(3).map { shortSymbol($0.0) }
            }
            if !hot.isEmpty {
                emit("[budget]   samples=\(taken.count) hottest app frames:")
                for (frame, count) in hot { emit("[budget]     \(count)x \(frame)") }
            } else if taken.isEmpty {
                emit("[budget]   samples=0 (the watchdog took none: the turn ended before its first 2ms tick)")
            }
            if traps {
                fatalError("[budget] TRAP: \(name) took \(format(elapsed))ms in its presentation turn, budget \(budgetMs)ms — see the log above")
            }
        }
        publishProbe()
    }

    private static func publishProbe() {
        probe.accessibilityIdentifier = "budget;turns=\(turns);screens=\(screenTurns);over=\(overTurns)"
            + ";worst=\(worst.name.isEmpty ? "none" : worst.name):\(Int(worst.ms.rounded()))"
            + ";hot=\(worstHot.joined(separator: "|"))"
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        else { return }
        if probe.superview !== window { window.addSubview(probe) }
        window.bringSubviewToFront(probe)
    }

    // MARK: - Screen events

    fileprivate static func noteViewDidLoad(_ controller: UIViewController) {
        note("load:\(String(describing: type(of: controller)))")
    }

    fileprivate static func noteFirstLayout(of controller: UIViewController) {
        note("layout:\(String(describing: type(of: controller)))")
    }

    /// An event with no turn open (the very first callout after install, or
    /// a mode the observers are not in) opens one late rather than vanishing:
    /// the number is then a floor, and the line says so.
    private static func note(_ event: String) {
        if !inTurn {
            beginTurn()
            turnEvents.append("(late-start)")
        }
        turnEvents.append(event)
    }

    fileprivate static func beginTimedLoad(_ controller: UIViewController) {
        loadStack.append((ObjectIdentifier(controller), CFAbsoluteTimeGetCurrent()))
    }

    fileprivate static func endTimedLoad(_ controller: UIViewController) {
        guard let last = loadStack.popLast() else { return }
        // Only the OUTERMOST override of a subclass chain reports.
        guard !loadStack.contains(where: { $0.instance == last.instance }) else { return }
        let ms = (CFAbsoluteTimeGetCurrent() - last.start) * 1000
        if inTurn { turnLoads.append((String(describing: type(of: controller)), ms)) }
    }

    /// Walks the class list once and wraps every `viewDidLoad` the app's own
    /// image defines. A wrapper calls the original through its IMP, so a
    /// subclass calling `super.viewDidLoad()` reaches its parent's wrapper,
    /// and the depth guard in `endTimedLoad` keeps one report per instance.
    private static func wrapViewDidLoadOverrides() -> Int {
        let selector = #selector(UIViewController.viewDidLoad)
        var count = 0
        // Only the app's own images are asked for their classes: walking the
        // whole class list (objc_copyClassList) touched ~100k classes and took
        // seconds, and reading it as `AnyClass` messaged NSProxy-style classes
        // that abort on any message. `objc_copyClassNamesForImage` walks one
        // image's table and hands back names, and `objc_getClass` on a name
        // realizes only the classes this harness cares about.
        for imageIndex in 0..<_dyld_image_count() {
            guard let imageName = _dyld_get_image_name(imageIndex), isAppImage(imageName) else { continue }
            var nameCount: UInt32 = 0
            guard let names = objc_copyClassNamesForImage(imageName, &nameCount) else { continue }
            defer { free(names) }
            for nameIndex in 0..<Int(nameCount) {
                guard let cls = objc_getClass(names[nameIndex]) as? AnyClass,
                      isViewController(cls),
                      let method = ownMethod(cls, selector)
                else { continue }
                let original = method_getImplementation(method)
                typealias Original = @convention(c) (UIViewController, Selector) -> Void
                let call = unsafeBitCast(original, to: Original.self)
                let block: @convention(block) (UIViewController) -> Void = { controller in
                    MainActor.assumeIsolated {
                        beginTimedLoad(controller)
                        call(controller, selector)
                        endTimedLoad(controller)
                    }
                }
                method_setImplementation(method, imp_implementationWithBlock(block))
                count += 1
            }
        }
        return count
    }

    /// The app's code is not in its executable alone: Xcode links it into
    /// `<app>.debug.dylib` inside the bundle, so "the app's own" means any
    /// image under the bundle path.
    nonisolated(unsafe) private static let appBundlePath: String =
        (Bundle.main.bundlePath as NSString).resolvingSymlinksInPath + "/"
    /// Keyed by the C string's ADDRESS: the runtime hands the same pointer for
    /// every class and frame of one image, and resolving symlinks costs an
    /// `lstat` chain per call.
    nonisolated(unsafe) private static var imageVerdicts: [UnsafePointer<CChar>: Bool] = [:]
    nonisolated(unsafe) private static let imageLock = NSLock()

    nonisolated private static func isAppImage(_ name: UnsafePointer<CChar>?) -> Bool {
        guard let name else { return false }
        imageLock.lock()
        defer { imageLock.unlock() }
        if let known = imageVerdicts[name] { return known }
        let verdict = (String(cString: name) as NSString).resolvingSymlinksInPath.hasPrefix(appBundlePath)
        imageVerdicts[name] = verdict
        return verdict
    }

    private static func isViewController(_ cls: AnyClass) -> Bool {
        var current: AnyClass? = cls
        while let c = current {
            if c == UIViewController.self { return true }
            current = class_getSuperclass(c)
        }
        return false
    }

    /// The method as THIS class defines it — not one inherited from a parent.
    private static func ownMethod(_ cls: AnyClass, _ selector: Selector) -> Method? {
        var count: UInt32 = 0
        guard let methods = class_copyMethodList(cls, &count) else { return nil }
        defer { free(methods) }
        for index in 0..<Int(count) where method_getName(methods[index]) == selector {
            return methods[index]
        }
        return nil
    }

    private static func swizzleBaseViewDidLoad() {
        guard let original = class_getInstanceMethod(UIViewController.self, #selector(UIViewController.viewDidLoad)),
              let marked = class_getInstanceMethod(
                UIViewController.self, #selector(UIViewController.presentationBudget_viewDidLoad))
        else { emit("[budget] FAILED to install: viewDidLoad not found"); return }
        method_exchangeImplementations(original, marked)
    }

    private static func swizzleLayoutSubviews() {
        guard let original = class_getInstanceMethod(UIView.self, #selector(UIView.layoutSubviews)),
              let marked = class_getInstanceMethod(
                UIView.self, #selector(UIView.presentationBudget_layoutSubviews))
        else { emit("[budget] FAILED to install: layoutSubviews not found"); return }
        method_exchangeImplementations(original, marked)
    }

    // MARK: - The watchdog sampler

    private static func startSampler() {
        mainMachThread = pthread_mach_thread_np(pthread_self())
        let top = UInt(bitPattern: pthread_get_stackaddr_np(pthread_self()))
        let size = UInt(pthread_get_stacksize_np(pthread_self()))
        mainStackTop = top
        mainStackBottom = top &- size
        let thread = Thread {
            while true {
                usleep(2000)
                samplerLock.lock()
                let armed = samplerArmed
                let start = samplerTurnStart
                let full = samples.count >= 256
                samplerLock.unlock()
                guard armed, !full, (CFAbsoluteTimeGetCurrent() - start) * 1000 > budgetMs else { continue }
                let frames = sampleMainThread()
                guard !frames.isEmpty else { continue }
                samplerLock.lock()
                if samplerArmed, samplerTurnStart == start { samples.append(frames) }
                samplerLock.unlock()
            }
        }
        thread.name = "presentation-budget-sampler"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Suspends the main thread, walks its frame pointers, resumes it. Raw
    /// addresses only while suspended — `dladdr` takes locks the main thread
    /// may hold.
    nonisolated private static func sampleMainThread() -> [UInt] {
        #if arch(arm64)
        // ⚠️ Nothing may allocate while the main thread is suspended: it may
        // hold the malloc lock, and the sampler would wait for it forever.
        // The array is sized before the suspend and only written to after.
        var frames = [UInt](repeating: 0, count: 64)
        var filled = 0
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        guard thread_suspend(mainMachThread) == KERN_SUCCESS else { return [] }
        let result = withUnsafeMutablePointer(to: &state) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(mainMachThread, thread_state_flavor_t(ARM_THREAD_STATE64), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { thread_resume(mainMachThread); return [] }
        frames[0] = UInt(state.__pc)
        frames[1] = UInt(state.__lr)
        filled = 2
        var fp = UInt(state.__fp)
        while filled < 64 {
            guard fp >= mainStackBottom, fp + 16 <= mainStackTop, fp % 8 == 0 else { break }
            let slot = UnsafePointer<UInt>(bitPattern: fp)!
            let next = slot.pointee
            let ret = slot.advanced(by: 1).pointee
            guard ret != 0 else { break }
            frames[filled] = ret
            filled += 1
            guard next > fp else { break }
            fp = next
        }
        thread_resume(mainMachThread)
        return Array(frames.prefix(filled))
        #else
        return []
        #endif
    }

    /// The app's own symbols across every sample, most frequent first. A
    /// sample counts each symbol once, so a deep recursion does not outvote a
    /// hot leaf.
    nonisolated private static func hottestFrames(in samples: [[UInt]]) -> [(String, Int)] {
        guard !samples.isEmpty else { return [] }
        var counts: [String: Int] = [:]
        var order: [String] = []
        for sample in samples {
            var seen = Set<String>()
            for address in sample {
                var info = Dl_info()
                guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0,
                      isAppImage(info.dli_fname),
                      let symbol = info.dli_sname.map({ canonical(demangle(String(cString: $0))) }),
                      !isNoise(symbol)
                else { continue }
                guard seen.insert(symbol).inserted else { continue }
                if counts[symbol] == nil { order.append(symbol) }
                counts[symbol, default: 0] += 1
            }
        }
        return order.map { ($0, counts[$0] ?? 0) }
            .sorted { $0.1 > $1.1 }
            .prefix(12)
            .map { ($0.0, $0.1) }
    }

    private typealias Demangle = @convention(c) (
        UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32
    ) -> UnsafeMutablePointer<CChar>?
    nonisolated(unsafe) private static let demangler: Demangle? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle") else { return nil }
        return unsafeBitCast(symbol, to: Demangle.self)
    }()

    nonisolated private static func demangle(_ name: String) -> String {
        guard let demangler, name.hasPrefix("$s") || name.hasPrefix("_$s") else { return name }
        guard let result = name.withCString({ demangler($0, strlen($0), nil, nil, 0) }) else { return name }
        defer { free(result) }
        return String(cString: result)
    }

    /// Frames that are in every sample and name nothing: the entry point,
    /// and the thunks Swift puts between a closure and its caller.
    nonisolated private static func isNoise(_ symbol: String) -> Bool {
        symbol.hasPrefix("reabstraction thunk")
            || symbol.hasPrefix("partial apply forwarder")
            || symbol.contains("MainActor.assumeIsolated")
            || symbol.hasSuffix("$main() -> ()")
            || symbol.contains("UIApplicationDelegate.main()")
            || symbol.contains("main_executable_dylib_entry_point")
            || symbol.contains("PresentationBudget")
    }

    /// `@objc Foo.bar()` and `Foo.bar()` are one frame to a reader.
    nonisolated private static func canonical(_ symbol: String) -> String {
        symbol.hasPrefix("@objc ") ? String(symbol.dropFirst(6)) : symbol
    }

    /// A symbol as the probe carries it: the private-name wrapper Swift
    /// mangles in (`(configureViews in _F444…)` → `configureViews`), a
    /// closure named by what it is in, no parameter list, the last two
    /// dotted parts, capped, and without the probe's own separators.
    nonisolated private static func shortSymbol(_ symbol: String) -> String {
        var text = symbol
        if let regex = try? NSRegularExpression(pattern: #"\((\w+) in _[0-9A-Fa-f]+\)"#) {
            text = regex.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1")
        }
        if text.hasPrefix("closure") || text.hasPrefix("implicit closure"),
           let range = text.range(of: " in ", options: .backwards) {
            text = String(text[range.upperBound...])
        }
        if let paren = text.firstIndex(of: "(") { text = String(text[..<paren]) }
        let parts = text.split(separator: ".")
        if parts.count > 2 { text = parts.suffix(2).joined(separator: ".") }
        text = text.replacingOccurrences(of: ";", with: ",").replacingOccurrences(of: "|", with: "/")
        return String(text.prefix(60))
    }

    nonisolated private static func format(_ ms: Double) -> String {
        String(format: "%.1f", ms)
    }

    private static func emit(_ text: String) {
        print(text)
        sink?.write(Data((text + "\n").utf8))
    }
}

extension UIViewController {
    /// Swapped with the base `viewDidLoad`; after the exchange, calling this
    /// name runs the original (empty) implementation. Fires at the top of
    /// every subclass's override that calls super, which is where the screen
    /// event is marked.
    @objc dynamic fileprivate func presentationBudget_viewDidLoad() {
        PresentationBudget.noteViewDidLoad(self)
        presentationBudget_viewDidLoad()
    }
}

extension UIView {
    nonisolated(unsafe) private static let presentationBudgetLaidOutKey =
        UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)

    /// Marks a controller root view's FIRST layout as a screen event of the
    /// turn it runs in. Composes with `FirstLayoutTrace`'s exchange: each
    /// wrapper calls the next through the exchanged name.
    @objc dynamic fileprivate func presentationBudget_layoutSubviews() {
        if objc_getAssociatedObject(self, UIView.presentationBudgetLaidOutKey) == nil {
            objc_setAssociatedObject(self, UIView.presentationBudgetLaidOutKey, true,
                                     .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            if window != nil, let controller = next as? UIViewController {
                PresentationBudget.noteFirstLayout(of: controller)
            }
        }
        presentationBudget_layoutSubviews()
    }
}

#endif
