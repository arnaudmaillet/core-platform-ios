import DesignSystem
import UIKit

/// Hold the bar's "+" to go straight to the camera: a glass disc rises over
/// the bubble with a camera in it, a ring round it fills while the finger
/// stays down, and the moment it is full the camera opens — the same
/// screen, by the same road, as the Create menu's Camera row. Letting go
/// before it is full, or sliding away, puts the disc back and does nothing.
///
/// THE HOLD ITSELF IS DESIGNSYSTEM'S `HoldToArmPresenter` (#1929), the one
/// the composer's slot uses: the timing, the ticks, the disc and its clock
/// live there once, so the two holds cannot drift apart. What stays here is
/// the "+"'s own: which touches are its, where its disc goes, and the lock
/// that keeps a hold from also opening the menu.
///
/// ```
///   touch ─ 0.22s ─▶ disc rises (light tick) ─ 0.6s fill ─▶ camera opens (medium tick)
///     │                   │
///     └ lifted: a TAP,    └ lifted / slid off: disc
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
        /// How long after a hold ends a selection of the "+" is still refused.
        /// A cancelled touch that the bar nonetheless turned into a selection
        /// would arrive within the same gesture's last turns; half a second
        /// is ample and still far shorter than a second, deliberate tap.
        static let selectionLockout: TimeInterval = 0.5
        /// The end bubble's inset from the bar's edge, for when the bar's own
        /// answer cannot be trusted (see `plusFrame`). Measured on iOS 27:
        /// the collapsed "+" sits 16 pt in from the trailing edge.
        static let trailingBubbleInset: CGFloat = 16
    }

    private let tab: UITab
    private weak var tabBarController: UITabBarController?
    private let fire: @MainActor () -> Void
    /// The hold, hung on the bar by `install`.
    private var presenter: HoldToArmPresenter?
    /// Whether a hold may arm, kept for a presenter not yet installed.
    private var wantsEnabled = true
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
    }

    /// Whether a hold may arm the camera at all. Off for a guest (#626): their
    /// bubble is "Sign in", and a hold on it does nothing special.
    var isEnabled: Bool {
        get { presenter?.isEnabled ?? wantsEnabled }
        set {
            wantsEnabled = newValue
            presenter?.isEnabled = newValue
        }
    }

    /// Hangs the hold on the bar. Idempotent.
    func install() {
        guard presenter == nil, let bar = tabBarController?.tabBar else { return }
        let presenter = HoldToArmPresenter(view: bar) { .symbol("camera.fill") }
        presenter.host = { [weak self] in self?.tabBarController?.view }
        presenter.discFrame = { [weak self] host in self?.discFrame(in: host) }
        presenter.onPressBegan = { [weak self] in
            self?.lockoutWork?.cancel()
            self?.consumesSelection = true
        }
        presenter.onPressFinished = { [weak self] in self?.releaseSelectionLockSoon() }
        presenter.onFire = { [weak self] in self?.fire() }
        presenter.gestureRecognizer.delegate = self
        presenter.gestureRecognizer.name = "CreateHoldShortcut"
        presenter.isEnabled = wantsEnabled
        self.presenter = presenter
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

    private func releaseSelectionLockSoon() {
        lockoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.consumesSelection = false }
        lockoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Metrics.selectionLockout, execute: work)
    }

    // MARK: - Where the disc goes

    /// Centred over the "+", clear of the screen's edges, above the bubble —
    /// and above the tab accessory too, when one is showing over the "+"'s
    /// side of the bar, so the disc never sits glass-on-glass over it.
    private func discFrame(in host: UIView) -> CGRect? {
        guard let bubble = plusFrame(in: host) else { return nil }
        let unclipped = HoldToArmPresenter.frame(over: bubble, in: host.bounds)
        var ceiling = bubble.minY
        if let accessory = tabBarController?.bottomAccessory?.contentView, accessory.window != nil,
           !accessory.isHidden {
            let frame = accessory.convert(accessory.bounds, to: host)
            let footprint = CGRect(x: unclipped.minX, y: frame.minY, width: unclipped.width, height: frame.height)
            if frame.intersects(footprint), frame.minY < ceiling { ceiling = frame.minY }
        }
        return HoldToArmPresenter.frame(over: bubble, ceiling: ceiling, in: host.bounds)
    }

    /// Where the "+" is, in `space`.
    ///
    /// ⚠️ **`UITab.frame(in:)` LIES WHILE THE BAR IS MINIMISED.** Scrolled
    /// down, the bar collapses to the selected tab's bubble on one side and
    /// the "+" on the other — and asked for the "+", iOS 27 answers with the
    /// OTHER bubble's rect (logged: `(28, 7, 48, 48)` for a "+" drawn at
    /// x≈349). So the hold never received a touch on the collapsed bar, and a
    /// long press fell through to the bar's own tap: the Create menu (device
    /// report, 26 September 2026).
    ///
    /// The "+" is always the bar's TRAILING bubble (leading in right-to-left)
    /// — a `UISearchTab` is laid out at the end, expanded or not. So a rect
    /// whose centre is not in that end third is rejected, and the end bubble
    /// is used instead, at the height and size the bar reported.
    private func plusFrame(in space: UIView) -> CGRect? {
        guard let bar = tabBarController?.tabBar,
              let reported = tab.frame(in: bar), !reported.isEmpty else { return nil }
        let isRTL = bar.effectiveUserInterfaceLayoutDirection == .rightToLeft
        let width = bar.bounds.width
        let plausible = isRTL ? reported.midX < width / 3 : reported.midX > width * 2 / 3
        var frame = reported
        if !plausible {
            let side = reported.height
            let x = isRTL
                ? bar.bounds.minX + Metrics.trailingBubbleInset
                : bar.bounds.maxX - Metrics.trailingBubbleInset - side
            frame = CGRect(x: x, y: reported.minY, width: side, height: side)
        }
        return bar.convert(frame, to: space)
    }
}

// MARK: - UIGestureRecognizerDelegate

extension CreateHoldShortcut: UIGestureRecognizerDelegate {
    /// Only touches that land on the "+", and only while nothing covers the
    /// bar. Every touch on the bar passes through here first — which is also
    /// where an old hold's selection lock is dropped: a new touch is a new
    /// decision.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard presenter?.isHolding != true else { return false }
        lockoutWork?.cancel()
        consumesSelection = false
        guard let bar = gestureRecognizer.view, let controller = tabBarController,
              controller.presentedViewController == nil,
              let bubble = plusFrame(in: bar) else { return false }
        return bubble.contains(touch.location(in: bar))
    }
}

#if DEBUG
// MARK: - QA hook

extension CreateHoldShortcut {
    /// Where a hold stands, for the QA hook's waits.
    var debugPhase: HoldToArm.Phase { presenter?.debugPhase ?? .idle }
    var debugProgress: CGFloat { presenter?.debugProgress ?? 0 }
    var debugDisc: HoldRingDiscView? { presenter?.debugDisc }

    /// The "+"'s centre in the bar, when the bar has placed it.
    var debugBubbleCentre: CGPoint? {
        guard let bar = tabBarController?.tabBar, let frame = plusFrame(in: bar) else { return nil }
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    /// A finger landing on the "+" and held past the recognition delay — the
    /// presenter's `.began`, through its own press path.
    func debugPress() {
        guard let centre = debugBubbleCentre else {
            QAWait.fail("-plus-hold-demo", "the + has no frame")
            return
        }
        presenter?.debugPress(at: centre)
    }

    /// The finger sliding by `offset` from the "+"'s centre (`.changed`).
    func debugDrag(by offset: CGVector) {
        guard let centre = debugBubbleCentre else { return }
        presenter?.debugMove(to: CGPoint(x: centre.x + offset.dx, y: centre.y + offset.dy))
    }

    /// The finger lifting (`.ended`).
    func debugRelease() { presenter?.debugRelease() }

    func debugLog(_ line: String) {
        FileHandle.standardError.write(Data(String(
            format: "[plus-hold] %.3f %@\n", ProcessInfo.processInfo.systemUptime, line
        ).utf8))
    }
}
#endif
