import DesignSystem
import ObjectiveC
import QuartzCore
import UIKit

// ⚠️ THE WHOLE FILE: a DEBUG harness, installed only under `-interaction-latency`.
#if DEBUG

/// The bookkeeping of `-interaction-latency` (#2116), free of UIKit so its
/// arithmetic is tested on its own: one input at a time, the responses that
/// follow it, the run-loop turns in between, the commit and the frame.
///
/// # The rule it measures
///
/// From the input's own timestamp (`UIEvent.timestamp`: the touch-up of a
/// tap, the release of a drag, the threshold of a long press) to the first
/// presented frame that shows the response: 100 ms at most.
///
/// # Which response
///
/// A tap can set off several things: a button's action at once, then a push
/// a few turns later behind an `await`. The response the rule is about is
/// the STRONGEST one, so a later, stronger response replaces a weaker one
/// for `window` seconds after the input:
///
///   - `.screen`: a controller appears or disappears (push, pop, present,
///     dismiss, a tab), or a menu or popover enters a window;
///   - `.action`: a control sends its action, a tap recognizer fires — the
///     app's own state change, measured at the turn that ran it;
///   - `.animation`: any animation added after the input — the last resort,
///     for a release that only springs something back. Not for a release
///     that set a scroll view decelerating: the content moving on is its
///     response, on the next frame, and the first animation after it is
///     whatever the scroll ends on (`dropAnimations`).
///
/// The first response is kept beside it, so a log line shows both the
/// instant feedback and the screen that came after.
public struct InteractionLatencyTracker: Sendable {
    public enum Strength: Int, Comparable, Sendable, CustomStringConvertible {
        case animation, action, screen
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
        public var description: String {
            switch self {
            case .animation: "animation"
            case .action: "action"
            case .screen: "screen"
            }
        }
    }

    public struct Input: Sendable, Equatable {
        public var kind: String
        public var target: String
        /// Seconds on the `CACurrentMediaTime` clock (`UIEvent.timestamp`'s).
        public var at: TimeInterval
        public init(kind: String, target: String, at: TimeInterval) {
            self.kind = kind
            self.target = target
            self.at = at
        }
    }

    public struct Record: Sendable, Equatable {
        public var input: Input
        public var response: String
        public var strength: Strength
        /// Input → the presented frame carrying the response.
        public var latencyMs: Double
        /// Input → the Core Animation commit carrying it.
        public var commitMs: Double
        /// Main-thread turns between the input and that commit.
        public var turns: Int
        /// Time the main thread spent in those turns…
        public var busyMs: Double
        /// …and time it waited: event delivery, and any async hop (`Task`,
        /// `main.async`, an `await`) the response was deferred by.
        public var idleMs: Double
        public var worstTurnMs: Double
        public var firstResponse: String
        public var firstLatencyMs: Double
    }

    struct Response {
        var name: String
        var strength: Strength
        var at: TimeInterval
        var commitAt: TimeInterval?
        var frameAt: TimeInterval?
    }

    /// How long after the input a stronger response still counts as its own.
    public var window: TimeInterval
    public private(set) var input: Input?
    private var best: Response?
    private var first: Response?
    private var ignoresAnimations = false
    private var turns: [(start: TimeInterval, end: TimeInterval)] = []

    /// 1.2 s: past it a response is ten times over the budget anyway, and a
    /// longer window would swallow the next tap of a quick sequence.
    public init(window: TimeInterval = 1.2) {
        self.window = window
    }

    /// A new input: the previous one is finished with what it has.
    public mutating func begin(_ next: Input) -> Record? {
        let flushed = finish()
        input = next
        return flushed
    }

    public mutating func respond(_ name: String, strength: Strength, at time: TimeInterval) {
        guard let input, time >= input.at, !(ignoresAnimations && strength == .animation) else { return }
        if first == nil { first = Response(name: name, strength: strength, at: time) }
        if let best, best.strength >= strength { return }
        best = Response(name: name, strength: strength, at: time)
    }

    /// A main-thread turn ended at `end`, after Core Animation's commit: it
    /// commits every response made in it. `presentedAt`, when the display's
    /// phase is known, is the frame that commit is shown in — the render
    /// server shows it whatever the main thread does next, so a hang in
    /// the following turn must not count.
    public mutating func turnEnded(start: TimeInterval, end: TimeInterval, presentedAt: TimeInterval? = nil) {
        guard let input, end >= input.at else { return }
        if best?.commitAt == nil { turns.append((max(start, input.at), end)) }
        commit(&best, at: end, presentedAt: presentedAt)
        commit(&first, at: end, presentedAt: presentedAt)
    }

    /// The frame a commit at `commit` is shown in: picked up at the first
    /// vsync after it, shown one frame later.
    public static func presented(commit: TimeInterval, vsync: TimeInterval, period: TimeInterval) -> TimeInterval {
        guard period > 0 else { return commit }
        let next = vsync + (max(0, commit - vsync) / period).rounded(.up) * period
        return next + period
    }

    /// A display frame: `vsync` is the frame the link fired for, `target`
    /// the next one. A response committed by `vsync` is on screen at
    /// `target` at the latest.
    public mutating func frame(vsync: TimeInterval, target: TimeInterval) {
        present(&best, vsync: vsync, target: target)
        present(&first, vsync: vsync, target: target)
    }

    /// The input set a scroll view decelerating: no animation is its
    /// response from now on, and one already noted is dropped. Only an
    /// action or a screen can still make it a record.
    public mutating func dropAnimations() {
        ignoresAnimations = true
        if best?.strength == .animation { best = nil }
        if first?.strength == .animation { first = best }
    }

    /// Any response yet: an animation can no longer change the record.
    public var hasResponse: Bool { first != nil }

    /// The strongest response so far has been committed.
    public var hasCommittedResponse: Bool { best?.commitAt != nil }

    public var needsFrame: Bool {
        (best?.commitAt != nil && best?.frameAt == nil) || (first?.commitAt != nil && first?.frameAt == nil)
    }

    /// The input is over once its window has run out.
    public mutating func expire(now: TimeInterval) -> Record? {
        guard let input, now - input.at >= window, !needsFrame else { return nil }
        return finish()
    }

    /// Why the last input ended without a record (a test's diagnosis).
    public private(set) var lastDrop = ""

    /// A screen response named after what APPEARS: a push calls the
    /// outgoing screen's `viewWillDisappear` first, in the same turn.
    public mutating func preferName(_ name: String) {
        guard var value = best, value.strength == .screen, value.commitAt == nil,
              value.name.hasPrefix("disappear:") else { return }
        value.name = name
        best = value
    }

    /// Ends the current input; a record only if it had a committed response.
    public mutating func finish() -> Record? {
        if let input {
            lastDrop = best == nil ? "\(input.target): no response"
                : best?.commitAt == nil ? "\(input.target): \(best!.name) never committed" : ""
        }
        defer {
            input = nil
            best = nil
            first = nil
            ignoresAnimations = false
            turns.removeAll(keepingCapacity: true)
        }
        guard let input, let best, let commit = best.commitAt else { return nil }
        let shown = best.frameAt ?? commit
        let counted = turns.filter { $0.end <= commit }
        let busy = counted.reduce(0) { $0 + ($1.end - $1.start) }
        let worst = counted.map { $0.end - $0.start }.max() ?? 0
        let firstShown = first.flatMap { $0.frameAt ?? $0.commitAt } ?? shown
        return Record(
            input: input,
            response: best.name,
            strength: best.strength,
            latencyMs: (shown - input.at) * 1000,
            commitMs: (commit - input.at) * 1000,
            turns: counted.count,
            busyMs: busy * 1000,
            idleMs: max(0, (commit - input.at) - busy) * 1000,
            worstTurnMs: worst * 1000,
            firstResponse: first?.name ?? best.name,
            firstLatencyMs: (firstShown - input.at) * 1000
        )
    }

    private func commit(_ response: inout Response?, at end: TimeInterval, presentedAt: TimeInterval?) {
        guard var value = response, value.commitAt == nil, value.at <= end else { return }
        value.commitAt = end
        value.frameAt = presentedAt
        response = value
    }

    private func present(_ response: inout Response?, vsync: TimeInterval, target: TimeInterval) {
        guard var value = response, let commit = value.commitAt, value.frameAt == nil, vsync >= commit else { return }
        value.frameAt = target
        response = value
    }
}

/// `-interaction-latency` (#2116): every input's time to its first frame on
/// screen, against the 100 ms rule (`dev/PRESENTATION_CHARTER.md` P16).
///
/// `-presentation-budget` times the turn that BUILDS a screen; it cannot see
/// a response deferred to a later turn by a `Task`, a `main.async`, an
/// `await` before the push, or a recognizer's delay. This harness starts the
/// clock at the input itself and stops it at the frame.
///
/// # How
///
///   - **The input:** `UIApplication.sendEvent` — the last finger up of a
///     touch sequence is a tap (or a release, past 10 pt of travel), stamped
///     with the event's own timestamp; a long-press-family recognizer
///     reaching `.began` is a long press, stamped at that moment.
///   - **The response** (see `InteractionLatencyTracker`): `viewWillAppear`
///     / `viewWillDisappear` (every push, pop, present, dismiss and tab), a
///     context menu or popover view entering a window; `UIControl`'s
///     `sendAction` and a tap recognizer firing; any `CALayer` animation.
///   - **The commit:** a run-loop observer after Core Animation's commit
///     (order 2 100 000) closes the turn the response was made in.
///   - **The frame:** the display's phase, kept by a display link: the
///     commit is picked up at the first vsync after it and shown one frame
///     later — an upper bound by at most one frame. Computed, not waited
///     for: the render server shows a commit even while the main thread
///     hangs in the next turn.
///
/// Hot frames: run with `-presentation-budget -presentation-budget-ms 50`
/// beside it, and the budget's sampler names the app frames of every turn
/// past 50 ms.
///
/// # Arguments
///
///   - `-interaction-latency`        install; log to console + `Documents/interaction-latency.log`
///   - `-interaction-latency-hud`    also a badge naming any action over 100 ms (amber from 60 ms)
///
/// A probe element on the key window (`latency;n=…;over=…;worst=…;last=…`)
/// gives a UI test the numbers. Absent from Release; nothing is hooked
/// unless the argument is passed.
@MainActor
public enum InteractionLatency {
    public static let budgetMs: Double = 100
    public static let atRiskMs: Double = 60

    public private(set) static var isInstalled = false
    public private(set) static var records: [InteractionLatencyTracker.Record] = []
    /// Called with every record, on the main actor (tests, the HUD).
    public static var onRecord: ((InteractionLatencyTracker.Record) -> Void)?
    /// A test's own objects only: the controller appearing, the control
    /// sending. Other suites push and tap in the same process, and the
    /// harness is one global clock. Nil (the app): everything counts.
    static var countsOnly: ((AnyObject) -> Bool)?

    private static var tracker = InteractionLatencyTracker()
    private static var turnStart: TimeInterval = 0
    private static var inTurn = false
    private static var touchDown: [ObjectIdentifier: CGPoint] = [:]
    private static var touchDownAt: TimeInterval = 0
    private static var lastTouchUp: TimeInterval = 0
    /// A long press began during the touch now down: its release is not a
    /// tap of its own (the menu it opened would read as the tap's response).
    private static var pressedDuringTouch = false
    /// The tapped view, named only when its input is recorded: describing
    /// it walks the view and responder chains, and in `sendEvent` that was
    /// ~5 ms ahead of the very delivery being measured.
    private static weak var targetView: UIView?
    private static var targetAt: TimeInterval = -1
    private static var installedAt: TimeInterval = 0
    private static var showsHUD = false
    private static var writesLog = false
    nonisolated(unsafe) private static var sink: FileHandle?
    nonisolated private static let logQueue = DispatchQueue(label: "interaction-latency-log", qos: .utility)
    private static let clock = FrameClock()
    /// The display's phase: a vsync and the frame period, from the clock's
    /// ticks. It runs for as long as the harness is installed.
    fileprivate static var phase: (vsync: TimeInterval, period: TimeInterval)?
    private static let probe = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    private static var hud: HUDWindow?

    /// Installs under `-interaction-latency`; nothing otherwise.
    public static func installIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.contains("-interaction-latency") else { return }
        install(log: true, hud: arguments.contains("-interaction-latency-hud"))
    }

    public static func install(log: Bool, hud showHUD: Bool) {
        guard !isInstalled else { return }
        isInstalled = true
        installedAt = CACurrentMediaTime()
        showsHUD = showHUD
        writesLog = log
        if log {
            let url = URL.documentsDirectory.appendingPathComponent("interaction-latency.log")
            try? Data().write(to: url)
            sink = try? FileHandle(forWritingTo: url)
        }
        installTurnObserver()
        clock.start()
        hookEvents()
        hookResponses()
        probe.isAccessibilityElement = true
        probe.isUserInteractionEnabled = false
        probe.accessibilityIdentifier = "latency;n=0;over=0;worst=none:0;last=none:0"
        emit("[latency] START budget=\(Int(budgetMs))ms at-risk=\(Int(atRiskMs))ms hud=\(showHUD)")
    }

    /// How long after an input a stronger response still counts (1.2 s).
    /// A test lengthens it, so a slow host's deferred response is never
    /// dropped before it lands, and ends the input itself (`finishInput`).
    static var responseWindow: TimeInterval {
        get { tracker.window }
        set { tracker.window = newValue }
    }

    /// Whether the current input's strongest response has been committed.
    static var hasCommittedResponse: Bool { tracker.hasCommittedResponse }

    /// Ends the current input now, recording it if it has a committed
    /// response — a test's deterministic end, instead of the window's.
    static func finishInput() {
        if let done = tracker.finish() { record(done) }
    }

    /// The tracker's state, for a test that reads none of its records.
    static var debugState: String {
        "input=\(tracker.input?.target ?? "nil") needsFrame=\(tracker.needsFrame) inTurn=\(inTurn)"
            + " lastDrop=\(tracker.lastDrop)"
    }

    // MARK: - Inputs

    /// An input from a test or a script, on the same clock as `UIEvent`.
    public static func noteInput(kind: String, target: String, at time: TimeInterval = CACurrentMediaTime()) {
        guard isInstalled else { return }
        if let flushed = tracker.begin(.init(kind: kind, target: target, at: time)) { record(flushed) }
        let window = tracker.window
        DispatchQueue.main.asyncAfter(deadline: .now() + window + 0.05) {
            MainActor.assumeIsolated { expireIfDue() }
        }
    }

    /// A response the hooks cannot see (a test, a custom surface).
    public static func noteResponse(_ name: String, strength: InteractionLatencyTracker.Strength = .screen) {
        guard isInstalled else { return }
        tracker.respond(name, strength: strength, at: CACurrentMediaTime())
    }

    fileprivate static func observe(_ event: UIEvent) {
        guard event.type == .touches, let touches = event.allTouches, !touches.isEmpty else { return }
        var ended: UITouch?
        var allUp = true
        for touch in touches {
            let id = ObjectIdentifier(touch)
            switch touch.phase {
            case .began:
                // A new sequence starts clean: a long press whose touch the
                // system cancelled (a context menu takes it) never saw its
                // release, and must not swallow this sequence's tap.
                if touchDown.isEmpty {
                    touchDownAt = touch.timestamp
                    pressedDuringTouch = false
                }
                touchDown[id] = touch.location(in: nil)
                allUp = false
            case .ended:
                ended = touch
            case .cancelled:
                break
            default:
                allUp = false
            }
        }
        guard allUp, let touch = ended else {
            if touches.allSatisfy({ $0.phase == .cancelled }) {
                touches.forEach { touchDown[ObjectIdentifier($0)] = nil }
            }
            return
        }
        let id = ObjectIdentifier(touch)
        let start = touchDown[id] ?? touch.location(in: nil)
        let end = touch.location(in: nil)
        touches.forEach { touchDown[ObjectIdentifier($0)] = nil }
        let travel = hypot(end.x - start.x, end.y - start.y)
        lastTouchUp = event.timestamp
        guard !pressedDuringTouch else {
            pressedDuringTouch = false
            return
        }
        // A view in a system container can be gone from the touch by its
        // end: the window's hit test names it then.
        let view = touch.view ?? touch.window?.hitTest(touch.location(in: touch.window), with: nil)
        // A key of the system's keyboard: the keyboard answers, not the app.
        if let view, String(describing: type(of: view)).hasPrefix("UIKeyboard") { return }
        // First: beginning this input records the previous one, which names
        // its own view from `targetView`.
        noteInput(kind: travel > 10 ? "release" : "tap", target: "", at: event.timestamp)
        targetView = view
        targetAt = event.timestamp
    }

    fileprivate static func observe(_ recognizer: UIGestureRecognizer, entering state: Int) {
        let name = String(describing: type(of: recognizer))
        // A press recognizer that begins on touch-down (a segmented bar's,
        // a text field's) is a tap's tracking, not a long press: the finger
        // must have been down 300 ms.
        if state == UIGestureRecognizer.State.began.rawValue, isPressRecognizer(name),
           !touchDown.isEmpty, CACurrentMediaTime() - touchDownAt >= 0.3 {
            pressedDuringTouch = true
            noteInput(kind: "long-press", target: describe(recognizer.view), at: CACurrentMediaTime())
        } else if state == UIGestureRecognizer.State.ended.rawValue, recognizer is UITapGestureRecognizer,
                  countsOnly == nil {
            tracker.respond("tap-recognizer@\(owner(of: recognizer.view))", strength: .action, at: CACurrentMediaTime())
        }
    }

    private static func isPressRecognizer(_ name: String) -> Bool {
        name.contains("LongPress") || name.contains("Click") || name.contains("TouchDuration")
            || name.contains("ContextMenu")
    }

    // MARK: - Responses

    fileprivate static var isArmed: Bool { tracker.input != nil }

    fileprivate static func respond(_ name: String, _ strength: InteractionLatencyTracker.Strength) {
        tracker.respond(name, strength: strength, at: CACurrentMediaTime())
    }

    /// Per class: whether a view of it entering a window is a menu or a
    /// popover. Cached, so the hook costs a lookup per view, not a string.
    private static var menuClasses: [ObjectIdentifier: Bool] = [:]

    fileprivate static func viewEnteredWindow(_ view: UIView) {
        let cls = ObjectIdentifier(type(of: view))
        let isMenu: Bool
        if let known = menuClasses[cls] {
            isMenu = known
        } else {
            let name = String(describing: type(of: view))
            isMenu = name.contains("ContextMenu") || name.contains("_UIMenu") || name.contains("Popover")
            menuClasses[cls] = isMenu
        }
        guard isMenu else { return }
        respond("menu:\(type(of: view))", .screen)
    }

    // MARK: - Turns and frames

    /// Unlike `-presentation-budget`, every level of a nested run loop
    /// counts: the outer level is not the same in a test host (which spins
    /// the main loop per test) as in the app, and a nested wait (a modal
    /// spin, a synchronous XPC call) on the way to a response is time the
    /// user waits all the same.
    private static func installTurnObserver() {
        let starter = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min
        ) { _, _ in MainActor.assumeIsolated { beginTurn() } }
        let ender = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, 2_100_000
        ) { _, _ in MainActor.assumeIsolated { endTurn() } }
        CFRunLoopAddObserver(CFRunLoopGetMain(), starter, .commonModes)
        CFRunLoopAddObserver(CFRunLoopGetMain(), ender, .commonModes)
    }

    private static func beginTurn() {
        guard !inTurn else { return }
        inTurn = true
        turnStart = CACurrentMediaTime()
    }

    private static func endTurn() {
        let end = CACurrentMediaTime()
        let start = inTurn ? turnStart : end
        inTurn = false
        let ms = (end - start) * 1000
        // A hang: a turn of 100 ms or more holds every frame of a scroll, a
        // drag or an animation (the table's last row). The launch is the
        // launch timeline's.
        if ms >= budgetMs, end - installedAt > 5 {
            let during = touchDown.isEmpty ? (end - lastTouchUp < 1 ? "after-touch" : "idle") : "touch-down"
            emit("[latency] HANG turn=\(format(ms))ms during=\(during)")
        }
        let presented = phase.map {
            InteractionLatencyTracker.presented(commit: end, vsync: $0.vsync, period: $0.period)
        }
        tracker.turnEnded(start: start, end: end, presentedAt: presented)
        expireIfDue()
    }

    fileprivate static func frame(vsync: TimeInterval, target: TimeInterval) {
        phase = (vsync, target - vsync)
        tracker.frame(vsync: vsync, target: target)
        if tracker.input != nil { expireIfDue() }
    }

    private static func expireIfDue() {
        if let done = tracker.expire(now: CACurrentMediaTime()) { record(done) }
    }

    // MARK: - Output

    private static var over = 0
    private static var worst: InteractionLatencyTracker.Record?

    private static func record(_ finished: InteractionLatencyTracker.Record) {
        var record = finished
        if record.input.target.isEmpty, record.input.at == targetAt {
            record.input.target = describe(targetView)
        }
        records.append(record)
        if records.count > 2000 { records.removeFirst(records.count - 2000) }
        let interactiveEnd = isInteractiveEnd(record)
        let verdict = interactiveEnd ? "INTERACTIVE-END"
            : record.latencyMs > budgetMs ? "OVER" : record.latencyMs >= atRiskMs ? "AT-RISK" : "ok"
        if record.latencyMs > budgetMs, !interactiveEnd { over += 1 }
        if record.latencyMs > (worst?.latencyMs ?? 0) { worst = record }
        var line = "[latency] \(format(record.latencyMs))ms \(verdict) \(record.input.kind) \(record.input.target)"
        line += " → \(record.response) (\(record.strength))"
        line += " commit=\(format(record.commitMs))ms turns=\(record.turns) busy=\(format(record.busyMs))ms"
        line += " idle=\(format(record.idleMs))ms worstTurn=\(format(record.worstTurnMs))ms"
        if record.firstResponse != record.response {
            line += " first=\(record.firstResponse)@\(format(record.firstLatencyMs))ms"
        }
        emit(line)
        publishProbe(last: record)
        // A scroll's release that only met an animation is not an action.
        if showsHUD, record.latencyMs >= atRiskMs, record.strength >= .action, !interactiveEnd { showBadge(record) }
        onRecord?(record)
    }

    private static func publishProbe(last: InteractionLatencyTracker.Record) {
        let worstName = worst.map { "\($0.response):\(Int($0.latencyMs.rounded()))" } ?? "none:0"
        probe.accessibilityIdentifier = "latency;n=\(records.count);over=\(over);worst=\(worstName)"
            + ";last=\(last.response):\(Int(last.latencyMs.rounded()))"
        guard let window = keyWindow() else { return }
        if probe.superview !== window { window.addSubview(probe) }
    }

    private static func showBadge(_ record: InteractionLatencyTracker.Record) {
        guard let scene = keyWindow()?.windowScene else { return }
        let badge = hud ?? HUDWindow(windowScene: scene)
        hud = badge
        badge.show("\(shortName(record.response)) \(Int(record.latencyMs.rounded())) ms",
                   over: record.latencyMs > budgetMs)
    }

    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }

    nonisolated private static func emit(_ line: String) {
        print(line)
        logQueue.async {
            guard let data = (line + "\n").data(using: .utf8) else { return }
            sink?.write(data)
        }
    }

    private static func format(_ ms: Double) -> String { String(format: "%.0f", ms) }

    private static func shortName(_ response: String) -> String {
        let parts = response.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return response }
        return "\(parts[0]) \(parts[1].replacingOccurrences(of: "ViewController", with: ""))"
    }

    // MARK: - Describing

    static func describe(_ view: UIView?) -> String {
        guard let view else { return "?" }
        var label: String?
        var current: UIView? = view
        var depth = 0
        while label == nil, let candidate = current, depth < 5 {
            label = candidate.accessibilityLabel ?? candidate.accessibilityIdentifier
            current = candidate.superview
            depth += 1
        }
        let text = label.map { " '\($0.prefix(28))'" } ?? ""
        return "\(type(of: view))\(text)@\(owner(of: view))"
    }

    static func owner(of view: UIView?) -> String {
        var responder: UIResponder? = view
        while let current = responder {
            if let controller = current as? UIViewController { return String(describing: type(of: controller)) }
            responder = current.next
        }
        return "?"
    }

    /// After the event that ended a release was delivered: a scroll view
    /// under the finger decelerating now took it as a fling.
    fileprivate static func delivered(_ event: UIEvent) {
        guard let input = tracker.input, input.kind == "release", input.at == event.timestamp,
              targetAt == event.timestamp else { return }
        var view = targetView
        while let current = view {
            if let scroll = current as? UIScrollView, scroll.isDecelerating {
                tracker.dropAnimations()
                return
            }
            view = current.superview
        }
    }

    /// Per class: whether a controller of it is the system's plumbing (the
    /// keyboard's window, accessory, prediction and editing bars, its
    /// prewarming, its remote host…) rather than a screen. Its appearing is
    /// not a response: a keyboard's dismissal calls its `viewWillDisappear`
    /// as the slide ends, not as it starts, and on a tap that also presents
    /// a sheet it would take the sheet's name. Cached, like `menuClasses`.
    private static var plumbingClasses: [ObjectIdentifier: Bool] = [:]

    static func isSystemPlumbing(_ controller: UIViewController) -> Bool {
        let cls: AnyClass = type(of: controller)
        if let known = plumbingClasses[ObjectIdentifier(cls)] { return known }
        // The system's classes live in its frameworks (a simulator's under
        // its runtime root); the app's and a test bundle's, elsewhere.
        let isSystem = Bundle(for: cls).bundlePath.contains("/System/Library/")
        let found = isSystemPlumbing(name: String(describing: cls), isSystem: isSystem)
        plumbingClasses[ObjectIdentifier(cls)] = found
        return found
    }

    /// The system's screens an app shows (containers, alerts, menus, share
    /// and pickers…). Any other system controller is plumbing: the device
    /// runs of 2026-11-05 met a new private name around the keyboard on each
    /// run, so the rule lists what counts, not what does not.
    static func isSystemPlumbing(name: String, isSystem: Bool) -> Bool {
        guard isSystem else { return false }
        let screens = ["UIViewController", "TableViewController", "CollectionViewController", "Navigation", "TabBar",
                       "Split", "PageViewController", "UIHostingController", "Alert", "Activity", "ContextMenu",
                       "Menu", "Popover", "Picker", "Safari", "Search", "Document", "Mail", "Message", "Preview",
                       "Camera"]
        return !screens.contains { name.contains($0) }
    }

    /// A release whose screen came after a wait: the end of an interactive
    /// transition (a swipe back, a sheet or a drawer let go, a pull to go
    /// back). The motion was on screen from the first frame; the screen
    /// reports at the end of the animation. Logged `INTERACTIVE-END`, not
    /// counted over the budget, no badge. A real slow screen behind a
    /// release would show busy time, not waiting.
    static func isInteractiveEnd(_ record: InteractionLatencyTracker.Record) -> Bool {
        record.input.kind == "release" && record.strength == .screen && record.idleMs > record.commitMs * 0.8
    }

    /// A repeating animation (a pulse, a looping avatar, a skeleton's sweep)
    /// runs whatever the finger does: it is nobody's response.
    static func isAmbient(_ animation: CAAnimation) -> Bool {
        animation.repeatCount > 0 || animation.repeatDuration > 0
    }

    // MARK: - Hooks

    private static func hookEvents() {
        typealias SendEvent = @convention(c) (UIApplication, Selector, UIEvent) -> Void
        replace(UIApplication.self, #selector(UIApplication.sendEvent(_:))) { (original: SendEvent, selector) in
            let block: @convention(block) (UIApplication, UIEvent) -> Void = { application, event in
                MainActor.assumeIsolated { observe(event) }
                original(application, selector, event)
                MainActor.assumeIsolated { delivered(event) }
            }
            return block
        }
        typealias SetState = @convention(c) (UIGestureRecognizer, Selector, Int) -> Void
        replace(UIGestureRecognizer.self, NSSelectorFromString("setState:")) { (original: SetState, selector) in
            let block: @convention(block) (UIGestureRecognizer, Int) -> Void = { recognizer, state in
                original(recognizer, selector, state)
                MainActor.assumeIsolated { observe(recognizer, entering: state) }
            }
            return block
        }
    }

    private static func hookResponses() {
        typealias Appearance = @convention(c) (UIViewController, Selector, Bool) -> Void
        for (selector, verb) in [
            (#selector(UIViewController.viewWillAppear(_:)), "appear"),
            (#selector(UIViewController.viewWillDisappear(_:)), "disappear"),
        ] {
            replace(UIViewController.self, selector) { (original: Appearance, selector) in
                let block: @convention(block) (UIViewController, Bool) -> Void = { controller, animated in
                    MainActor.assumeIsolated {
                        if isArmed, countsOnly?(controller) ?? true, !isSystemPlumbing(controller) {
                            let name = "\(verb):\(type(of: controller))"
                            respond(name, .screen)
                            if verb == "appear" { tracker.preferName(name) }
                        }
                    }
                    original(controller, selector, animated)
                }
                return block
            }
        }
        typealias MoveToWindow = @convention(c) (UIView, Selector) -> Void
        replace(UIView.self, #selector(UIView.didMoveToWindow)) { (original: MoveToWindow, selector) in
            let block: @convention(block) (UIView) -> Void = { view in
                original(view, selector)
                MainActor.assumeIsolated {
                    if isArmed, countsOnly == nil, view.window != nil { viewEnteredWindow(view) }
                }
            }
            return block
        }
        typealias SendAction = @convention(c) (UIControl, Selector, Selector, AnyObject?, UIEvent?) -> Void
        replace(UIControl.self, #selector(UIControl.sendAction(_:to:for:))) { (original: SendAction, selector) in
            let block: @convention(block) (UIControl, Selector, AnyObject?, UIEvent?) -> Void = { control, action, target, event in
                MainActor.assumeIsolated {
                    if isArmed, countsOnly?(control) ?? true {
                        respond("action:\(action)@\(type(of: control))", .action)
                    }
                }
                original(control, selector, action, target, event)
            }
            return block
        }
        // A `UIAction` reaches its handler through its own entry point, not
        // the target-action one.
        typealias SendUIAction = @convention(c) (UIControl, Selector, UIAction) -> Void
        replace(UIControl.self, #selector(UIControl.sendAction(_:) as (UIControl) -> (UIAction) -> Void)) {
            (original: SendUIAction, selector) in
            let block: @convention(block) (UIControl, UIAction) -> Void = { control, action in
                MainActor.assumeIsolated {
                    if isArmed, countsOnly?(control) ?? true {
                        respond("action:\(action.title.isEmpty ? "UIAction" : action.title)@\(type(of: control))", .action)
                    }
                }
                original(control, selector, action)
            }
            return block
        }
        typealias AddAnimation = @convention(c) (CALayer, Selector, CAAnimation, NSString?) -> Void
        replace(CALayer.self, #selector(CALayer.add(_:forKey:))) { (original: AddAnimation, selector) in
            let block: @convention(block) (CALayer, CAAnimation, NSString?) -> Void = { layer, animation, key in
                original(layer, selector, animation, key)
                guard Thread.isMainThread else { return }
                MainActor.assumeIsolated {
                    if isArmed, !tracker.hasResponse, countsOnly == nil, !isAmbient(animation) {
                        respond("animation:\(key.map { $0 as String } ?? "?")", .animation)
                    }
                }
            }
            return block
        }
    }

    /// Swaps `selector`'s implementation on `cls` for `make`'s block, which
    /// calls the original through the IMP it is handed. An inherited method
    /// is added to `cls` rather than changed on its parent.
    private static func replace<Original>(
        _ cls: AnyClass, _ selector: Selector, _ make: (Original, Selector) -> Any
    ) {
        guard let method = class_getInstanceMethod(cls, selector) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let implementation = imp_implementationWithBlock(make(original, selector))
        if !class_addMethod(cls, selector, implementation, method_getTypeEncoding(method)) {
            method_setImplementation(method, implementation)
        }
    }
}

/// The display link that keeps the display's phase, for as long as the
/// harness is installed.
@MainActor
private final class FrameClock: NSObject {
    private var link: CADisplayLink?

    func start() {
        if link == nil {
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        link?.isPaused = false
    }

    @objc private func tick(_ link: CADisplayLink) {
        InteractionLatency.frame(vsync: link.timestamp, target: link.targetTimestamp)
    }
}

/// `-interaction-latency-hud`: a badge under the status bar naming an action
/// over the budget (red) or at risk (amber), for 2.5 s. No animation: an
/// animation of its own would read as the next input's response.
@MainActor
private final class HUDWindow: AppWindow {
    private let label = UILabel()
    private var generation = 0

    override init(windowScene: UIWindowScene) {
        super.init(windowScene: windowScene)
        windowLevel = .alert + 10
        isUserInteractionEnabled = false
        backgroundColor = .clear
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .bold)
        label.textColor = .white
        label.textAlignment = .center
        label.layer.cornerRadius = 10
        label.layer.masksToBounds = true
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ text: String, over: Bool) {
        label.text = text
        label.backgroundColor = over ? .systemRed : UIColor.systemYellow.withAlphaComponent(0.9)
        label.textColor = over ? .white : .black
        let size = label.sizeThatFits(CGSize(width: 320, height: 20))
        let top = windowScene?.statusBarManager?.statusBarFrame.maxY ?? 44
        label.frame = CGRect(x: 0, y: 0, width: size.width + 20, height: 20)
        label.center = CGPoint(x: bounds.midX, y: top + 12)
        isHidden = false
        generation += 1
        let shown = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == shown else { return }
                self.isHidden = true
            }
        }
    }
}

#endif
