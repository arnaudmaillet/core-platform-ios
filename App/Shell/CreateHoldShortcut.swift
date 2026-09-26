import DesignSystem
import UIKit

/// Hold the bar's "+" to go straight to the camera: a glass disc rises over
/// the bubble with a camera in it, a ring round it fills while the finger
/// stays down, and letting go once it is full opens the camera — the same
/// screen, by the same road, as the Create menu's Camera row. Letting go
/// before it is full, or sliding away, puts the disc back and does nothing.
///
/// ```
///   touch ─ 0.22s ─▶ disc rises (light tick) ─ 0.6s fill ─▶ armed (medium tick, pop)
///     │                   │                                   │
///     └ lifted: a TAP,    └ lifted / slid off: disc           └ lifted: camera
///       the menu opens      shrinks back, nothing opens
/// ```
///
/// # Why a recogniser on the BAR, not on the overlay
///
/// The "+" already has an invisible button over it (`CreateTabItem.overlay`),
/// and it is deliberately an ANCHOR that takes no touch: when it took the
/// touch, the bubble lost its Liquid Glass press response — the one item in
/// the bar that stopped answering a finger. So this hangs a long press on the
/// tab bar itself, which sees every touch to its buttons on the way down, and
/// the delegate lets it look only at touches that land on the "+"
/// (`UITab.frame(in:)`: public, and it needs no accessibility runtime — see
/// `MainTabCoordinator.align`). The bubble still gets its touch, and still
/// swells under the finger, until the hold is recognised.
///
/// # Why a tap still opens the menu, and a hold never does
///
/// Before `minimumPressDuration` nothing here has happened: the recogniser is
/// only `.possible`, and a lift fails it, so the bar selects the "+" as
/// always and `shouldSelectTab` opens the menu. Once the hold is recognised it
/// cancels the touches it was watching (`cancelsTouchesInView`), and a
/// cancelled touch is not a tap: the bar never asks to select — measured
/// with real simulator touches (iOS 27): a filled hold, a short one and a
/// slide-off, and not one `shouldSelectTab` for the "+" after any of them.
/// As a second lock, independent of how the bar tracks its touches —
/// private, and free to change between releases — a recognised hold also sets
/// `consumesSelection`, and `shouldSelectTab` refuses one selection of the
/// "+" while it is set, opening nothing. It is cleared by the next touch that
/// lands on the bar and by a short timer after the hold ends, so a later
/// VoiceOver or keyboard activation (which arrives with no touch at all)
/// can never be swallowed by an old hold.
///
/// # Accessibility
///
/// The gesture is a SHORTCUT, never the only road: the Create menu still
/// offers Camera, and VoiceOver's activation of the "+" arrives with no touch
/// at all, straight in `shouldSelectTab` — the menu, as before. (A VoiceOver
/// double-tap-and-hold passes a touch through to the bubble and would most
/// likely drive this recogniser too; NOT verified — no VoiceOver run.) The
/// disc itself is not an accessibility element.
@MainActor
final class CreateHoldShortcut: NSObject {
    enum Metrics {
        /// How long a finger must stay on the "+" before the disc appears.
        ///
        /// ⚠️ **LONGER THAN A TAP, SHORTER THAN A HESITATION.** Measured taps
        /// in this app lift 32-98 ms after they land (`PressFeedback`), so
        /// 0.22 s is more than twice the slowest; any less and a deliberate
        /// tap that lingers would flash a disc on its way to the menu. Much
        /// more and the hold stops feeling like it answers.
        static let recognitionDelay: TimeInterval = 0.22
        /// How far the finger may roll before the hold is recognised, in
        /// points — the recogniser's own pre-recognition gate. The default
        /// 10 pt; after recognition `HoldToArm.abandonDistance` takes over.
        static let preRecognitionSlop: CGFloat = 10
        /// Gap between the disc and the top of whatever it floats over.
        static let gap: CGFloat = 12
        /// The disc never comes closer than this to the screen's edge.
        static let edgeMargin: CGFloat = 8
        /// How long after a hold ends a selection of the "+" is still refused.
        /// A cancelled touch that the bar nonetheless turned into a selection
        /// would arrive within the same gesture's last turns; half a second
        /// is ample and still far shorter than a second, deliberate tap.
        static let selectionLockout: TimeInterval = 0.5
    }

    private let tab: UITab
    private weak var tabBarController: UITabBarController?
    private let fire: @MainActor () -> Void
    private let recognizer = UILongPressGestureRecognizer()
    private var hold = HoldToArm()
    private var disc: HoldRingDiscView?
    private var displayLink: CADisplayLink?
    private let revealHaptic = UIImpactFeedbackGenerator(style: .light)
    private let armHaptic = UIImpactFeedbackGenerator(style: .medium)
    private var lockoutWork: DispatchWorkItem?

    /// Set when a hold is recognised: the one selection of the "+" the bar
    /// might still deliver for that touch is refused (see the type doc).
    private(set) var consumesSelection = false

    /// - Parameters:
    ///   - tab: the "+", whose frame decides which touches are this one's.
    ///   - fire: what a completed hold does — the Create menu's Camera row.
    init(tab: UITab, tabBarController: UITabBarController, fire: @escaping @MainActor () -> Void) {
        self.tab = tab
        self.tabBarController = tabBarController
        self.fire = fire
        super.init()
        recognizer.addTarget(self, action: #selector(handle(_:)))
        recognizer.minimumPressDuration = Metrics.recognitionDelay
        recognizer.allowableMovement = Metrics.preRecognitionSlop
        recognizer.delegate = self
        recognizer.name = "CreateHoldShortcut"
    }

    /// Hangs the recogniser on the bar. Idempotent.
    func install() {
        guard let bar = tabBarController?.tabBar, recognizer.view !== bar else { return }
        bar.addGestureRecognizer(recognizer)
    }

    /// Whether a selection of the "+" should be refused, consuming the lock.
    /// Asked by `shouldSelectTab` before it opens the menu.
    func consumeSelection() -> Bool {
        guard consumesSelection else { return false }
        consumesSelection = false
        #if DEBUG
        debugLog("refused a selection of the + after a hold")
        #endif
        return true
    }

    // MARK: - The gesture

    @objc private func handle(_ recognizer: UILongPressGestureRecognizer) {
        let location = recognizer.location(in: recognizer.view)
        switch recognizer.state {
        case .began:
            pressBegan(at: location)
        case .changed:
            pressMoved(to: location)
        case .ended:
            pressEnded()
        case .cancelled, .failed:
            pressCancelled()
        default:
            break
        }
    }

    /// The four inputs, shared by the recogniser and the QA hook so a
    /// scripted hold runs exactly the production path.
    private func pressBegan(at location: CGPoint) {
        lockoutWork?.cancel()
        consumesSelection = true
        guard let transition = hold.begin(at: CACurrentMediaTime(), location: location) else { return }
        apply(transition)
    }

    private func pressMoved(to location: CGPoint) {
        guard let transition = hold.move(to: location, at: CACurrentMediaTime()) else { return }
        apply(transition)
    }

    private func pressEnded() {
        let transition = hold.end(at: CACurrentMediaTime())
        releaseSelectionLockSoon()
        if let transition { apply(transition) }
    }

    private func pressCancelled() {
        let transition = hold.cancel()
        releaseSelectionLockSoon()
        if let transition { apply(transition) }
    }

    private func releaseSelectionLockSoon() {
        lockoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.consumesSelection = false }
        lockoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Metrics.selectionLockout, execute: work)
    }

    // MARK: - Showing it

    private func apply(_ transition: HoldToArm.Transition) {
        #if DEBUG
        debugLog("transition \(transition)")
        #endif
        switch transition {
        case .revealed:
            showDisc()
            revealHaptic.impactOccurred()
            armHaptic.prepare()
            startClock()
        case .armed:
            stopClock()
            disc?.setArmed(true)
            armHaptic.impactOccurred()
        case .fired:
            stopClock()
            disc?.dismiss(.launch)
            disc = nil
            fire()
        case .retracted, .abandoned:
            stopClock()
            disc?.dismiss(.retract)
            disc = nil
        }
    }

    private func showDisc() {
        guard let host = tabBarController?.view, let frame = discFrame(in: host) else { return }
        disc?.removeFromSuperview()
        let disc = HoldRingDiscView(symbolName: "camera.fill")
        disc.frame = frame
        host.addSubview(disc)
        disc.appear()
        self.disc = disc
    }

    /// Centred over the "+", clear of the screen's edges, above the bubble —
    /// and above the tab accessory too, when one is showing over the "+"'s
    /// side of the bar, so the disc never sits glass-on-glass over it.
    private func discFrame(in host: UIView) -> CGRect? {
        guard let bubble = tab.frame(in: host), !bubble.isEmpty else { return nil }
        let side = HoldRingDiscView.Metrics.diameter
        let bounds = host.bounds
        let margin = Metrics.edgeMargin + side / 2
        let midX = min(max(bubble.midX, bounds.minX + margin), bounds.maxX - margin)
        var ceiling = bubble.minY
        if let accessory = tabBarController?.bottomAccessory?.contentView, accessory.window != nil,
           !accessory.isHidden {
            let frame = accessory.convert(accessory.bounds, to: host)
            let footprint = CGRect(x: midX - side / 2, y: frame.minY, width: side, height: frame.height)
            if frame.intersects(footprint), frame.minY < ceiling { ceiling = frame.minY }
        }
        return CGRect(x: midX - side / 2, y: ceiling - Metrics.gap - side, width: side, height: side)
    }

    // MARK: - The clock

    private func startClock() {
        stopClock()
        let link = CADisplayLink(target: self, selector: #selector(clockTicked))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopClock() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func clockTicked() {
        let now = CACurrentMediaTime()
        disc?.setProgress(hold.progress(at: now))
        if let transition = hold.tick(at: now) { apply(transition) }
    }
}

// MARK: - UIGestureRecognizerDelegate

extension CreateHoldShortcut: UIGestureRecognizerDelegate {
    /// Only touches that land on the "+", and only while nothing covers the
    /// bar. Every touch on the bar passes through here first — which is also
    /// where an old hold's selection lock is dropped: a new touch is a new
    /// decision.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard !hold.isEngaged else { return false }
        lockoutWork?.cancel()
        consumesSelection = false
        guard let bar = gestureRecognizer.view, let controller = tabBarController,
              controller.presentedViewController == nil,
              let bubble = tab.frame(in: bar), !bubble.isEmpty else { return false }
        return bubble.contains(touch.location(in: bar))
    }
}

#if DEBUG
// MARK: - QA hook

extension CreateHoldShortcut {
    /// Where a hold stands, for the QA hook's waits.
    var debugPhase: HoldToArm.Phase { hold.phase }
    var debugProgress: CGFloat { hold.progress(at: CACurrentMediaTime()) }
    var debugDisc: HoldRingDiscView? { disc }

    /// The "+"'s centre in the bar, when the bar has placed it.
    var debugBubbleCentre: CGPoint? {
        guard let bar = tabBarController?.tabBar, let frame = tab.frame(in: bar), !frame.isEmpty else { return nil }
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    /// A finger landing on the "+" and held past the recognition delay — the
    /// recogniser's `.began`, through the same `pressBegan`.
    func debugPress() {
        guard let centre = debugBubbleCentre else {
            QAWait.fail("-plus-hold-demo", "the + has no frame")
            return
        }
        pressBegan(at: centre)
    }

    /// The finger sliding by `offset` from the "+"'s centre (`.changed`).
    func debugDrag(by offset: CGVector) {
        guard let centre = debugBubbleCentre else { return }
        pressMoved(to: CGPoint(x: centre.x + offset.dx, y: centre.y + offset.dy))
    }

    /// The finger lifting (`.ended`).
    func debugRelease() { pressEnded() }

    func debugLog(_ line: String) {
        FileHandle.standardError.write(Data(String(
            format: "[plus-hold] %.3f %@\n", ProcessInfo.processInfo.systemUptime, line
        ).utf8))
    }
}
#endif
