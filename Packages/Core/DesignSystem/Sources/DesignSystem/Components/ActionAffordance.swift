import ObjectiveC
import UIKit

/// The one way a CARD ACTION answers a finger — the chips under a post's
/// preview (comments, likes, repost, save), whatever the post holds.
///
/// ```
///   finger down          held ≥ 0.25s                 lift inside
///   ┌──────┐  0.1s       ┌──────┐  soft tick          ┌──────┐
///   │ ♥ 10 │ ─────▶      │▓♥ 10▓│ ─────▶ scroll       │ ♥ 20 │  action
///   └──────┘  gives,     └──────┘  frozen until       └──────┘
///             deepens              the lift
/// ```
///
/// ⚠️ **ONE COMPONENT, BECAUSE THE CARD HAD FOUR ANSWERS.** Reported from a
/// device on 26 September 2026: the comment chip of a MEDIA post shrank under
/// the finger while the same chip on a TEXT post did nothing at all — as if
/// the button were broken — and the like chip was not a control yet. Each chip
/// had wired its own recogniser and its own press. This owns all of it: the
/// press (`PressFeedback`), a contrast step, the hold, the tap, the menu.
///
/// ⚠️ **A HELD CHIP FREEZES EVERYTHING ELSE UNTIL THE LIFT.** The hold is a
/// `UILongPressGestureRecognizer`, and a long press that RECOGNISES prevents
/// every recogniser still waiting that does not recognise simultaneously with
/// it — the collection's pan, a pager's, the stack's back-swipe (measured in
/// this codebase the hard way: a recognised long press froze Upload's timeline
/// scroll). That is the behaviour asked for here, so it is used on purpose: a
/// finger that has settled on a control owns the screen until it lifts. A
/// finger that MOVES first (more than `allowableMovement`) fails the hold, and
/// the scroll it was starting proceeds exactly as before.
///
/// ⚠️ **THE CONTRAST STEP, NOT A FADE.** The app-wide press is a light shrink
/// and a slight fade (#221). On a chip that reads as "disabled" as much as
/// "pressed", so these deepen instead: a `.label` wash inside the capsule —
/// darker in light mode, lighter in dark, the direction the system's own
/// highlighted cells take — one step on the press and a second on the hold,
/// so a held chip says it is held.
///
/// ⚠️ **A TAP IS DECIDED ONCE.** A quick lift is the tap recogniser's (it
/// waits for the hold to fail, which a lift before `holdDuration` does at
/// once — no added latency); a lift after the hold is the hold's, inside the
/// chip. Never both, so the action cannot fire twice.
@MainActor
public final class ActionAffordance: NSObject {
    public enum Metrics {
        /// How long a finger rests before the chip counts as HELD — and the
        /// rest of the screen freezes. Shorter than a context menu's own
        /// timing, so the held state is visible before a menu lifts.
        public static let holdDuration: TimeInterval = 0.25
        /// The `.label` wash on a press, then on a hold. Measured on the card's
        /// capsule (227 in light mode): 0.08 lands at ~209, 0.16 at ~191 —
        /// two steps an eye tells apart without either reading as a new colour.
        public static let pressedWash: CGFloat = 0.08
        public static let heldWash: CGFloat = 0.16
        /// The wash follows the press's own response.
        public static let washResponse: TimeInterval = PressFeedback.Metrics.response
    }

    /// Fired by a tap, or by a hold released inside the chip.
    public var onTap: (() -> Void)?

    /// A menu raised by pressing and holding; nil for a chip without one.
    /// Built at presentation time, so it always reads current state.
    public var menuProvider: (() -> UIMenu?)? {
        didSet { syncMenuInteraction() }
    }

    /// Whether a finger has held the chip past `holdDuration`.
    public private(set) var isHeld = false

    private weak var view: UIView?
    private let wash = UIView()
    private let feedback: PressFeedback
    private let tap = UITapGestureRecognizer()
    private let hold = UILongPressGestureRecognizer()
    private var menuInteraction: UIContextMenuInteraction?
    private var isHeldInside = false

    /// Makes `view` a card action, or returns the affordance it already has
    /// (handing it the new `onTap`).
    ///
    /// - Parameter host: where the wash is drawn — the chip's CONTENT view for
    ///   a material chip, so the capsule deepens under its glyphs rather than
    ///   over them. Defaults to `view`.
    @discardableResult
    public static func attach(
        to view: UIView, washingIn host: UIView? = nil, onTap: (() -> Void)? = nil
    ) -> ActionAffordance {
        if let existing = attached(to: view) {
            existing.onTap = onTap
            return existing
        }
        let affordance = ActionAffordance(view: view, host: host ?? view)
        affordance.onTap = onTap
        objc_setAssociatedObject(view, &Association.key, affordance, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return affordance
    }

    /// The affordance on `view`, if it has one.
    public static func attached(to view: UIView) -> ActionAffordance? {
        objc_getAssociatedObject(view, &Association.key) as? ActionAffordance
    }

    private enum Association {
        nonisolated(unsafe) static var key: UInt8 = 0
    }

    private init(view: UIView, host: UIView) {
        self.view = view
        // Silent: the chip's action is the feedback. No fade: the wash below
        // is this component's answer to "pressed".
        feedback = PressFeedback.attach(toView: view, sound: nil, dims: false)
        super.init()
        view.isUserInteractionEnabled = true
        view.isAccessibilityElement = true
        view.accessibilityTraits.insert(.button)

        wash.backgroundColor = .label
        wash.alpha = 0
        wash.isUserInteractionEnabled = false
        wash.frame = host.bounds
        wash.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        wash.cornerConfiguration = .capsule()
        host.insertSubview(wash, at: 0)

        feedback.onPressChanged = { [weak self] _ in self?.applyWash() }

        hold.minimumPressDuration = Metrics.holdDuration
        hold.addTarget(self, action: #selector(holdChanged(_:)))
        hold.delegate = self
        // ⚠️ TRUE, so a held chip's lift never also SELECTS the cell under
        // it: the row would open the post on top of the chip's own action.
        hold.cancelsTouchesInView = true
        view.addGestureRecognizer(hold)

        tap.addTarget(self, action: #selector(tapped))
        // Same reason: the row's own tap opens the post, and a chip that let
        // the touch through would do both.
        tap.cancelsTouchesInView = true
        tap.require(toFail: hold)
        view.addGestureRecognizer(tap)
    }

    // MARK: - Tap and hold

    @objc private func tapped() {
        onTap?()
    }

    @objc private func holdChanged(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            isHeld = true
            isHeldInside = true
            applyWash()
            // The tick that says "held — the screen is yours". A chip with a
            // menu is about to get the menu's own, and two in half a second
            // is one too many.
            if menuProvider == nil {
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            }
        case .changed:
            let inside = isInside(recognizer)
            guard inside != isHeldInside else { return }
            isHeldInside = inside
            applyWash()
        case .ended:
            let inside = isInside(recognizer)
            endHold()
            if inside { onTap?() }
        case .cancelled, .failed:
            endHold()
        default:
            break
        }
    }

    private func isInside(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let view else { return false }
        return view.point(inside: recognizer.location(in: view), with: nil)
    }

    private func endHold() {
        isHeld = false
        isHeldInside = false
        applyWash()
    }

    /// The wash for the current state: held-and-inside, pressed, or nothing.
    private func applyWash() {
        let target: CGFloat = isHeld && isHeldInside
            ? Metrics.heldWash
            : (feedback.isPressed ? Metrics.pressedWash : 0)
        guard wash.alpha != target else { return }
        UIView.animate(
            withDuration: Metrics.washResponse, delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]
        ) {
            self.wash.alpha = target
        }
    }

    // MARK: - Menu

    private func syncMenuInteraction() {
        guard let view else { return }
        if menuProvider != nil, menuInteraction == nil {
            let interaction = UIContextMenuInteraction(delegate: self)
            view.addInteraction(interaction)
            menuInteraction = interaction
        } else if menuProvider == nil, let interaction = menuInteraction {
            view.removeInteraction(interaction)
            menuInteraction = nil
        }
    }

    /// The chip lifted as ITSELF — its capsule, not a rectangle around it.
    private func capsulePreview() -> UITargetedPreview? {
        guard let view, view.window != nil else { return nil }
        let parameters = UIPreviewParameters()
        parameters.visiblePath = UIBezierPath(
            roundedRect: view.bounds, cornerRadius: view.bounds.height / 2
        )
        parameters.backgroundColor = .clear
        return UITargetedPreview(view: view, parameters: parameters)
    }

    // MARK: - Tests

    #if DEBUG
    /// Internal for tests and QA hooks: what a tap would do.
    public func debugTap() { tapped() }

    /// Internal for tests: a hold beginning, then lifting inside or outside.
    public func debugHold(liftInside inside: Bool) {
        isHeld = true
        isHeldInside = true
        applyWash()
        endHold()
        if inside { onTap?() }
    }

    /// Internal for tests: the wash's current target.
    public var debugWashAlpha: CGFloat { wash.alpha }

    /// Internal for tests: the recognisers this installed.
    public var debugHoldRecognizer: UILongPressGestureRecognizer { hold }
    public var debugTapRecognizer: UITapGestureRecognizer { tap }
    public var debugHasMenu: Bool { menuInteraction != nil }
    #endif
}

extension ActionAffordance: UIGestureRecognizerDelegate {
    /// The hold shares the touch with the chip's OWN watchers — the press
    /// feedback's, the menu's — and with nothing above it. Everything above
    /// (the scrollers, the pager, the back-swipe) is exactly what a
    /// recognised hold is meant to prevent.
    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        guard gestureRecognizer === hold, let view, let otherView = other.view else { return false }
        return otherView.isDescendant(of: view)
    }
}

extension ActionAffordance: UIContextMenuInteractionDelegate {
    public func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let menuProvider else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            menuProvider()
        }
    }

    public func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configuration: UIContextMenuConfiguration,
        highlightPreviewForItemWithIdentifier identifier: any NSCopying
    ) -> UITargetedPreview? {
        capsulePreview()
    }

    public func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configuration: UIContextMenuConfiguration,
        dismissalPreviewForItemWithIdentifier identifier: any NSCopying
    ) -> UITargetedPreview? {
        capsulePreview()
    }
}
