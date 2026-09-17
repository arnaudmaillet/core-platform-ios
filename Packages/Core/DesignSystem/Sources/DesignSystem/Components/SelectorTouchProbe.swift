import UIKit

/// Reports a touch on a control without taking it.
///
/// ⚠️ **NOT `.touchDown` ON THE CONTROL, AND `PagedTabBar` BEING A `UIControl`
/// IS THE TRAP.** The obvious spelling is `addAction(for: [.touchDown, …])`,
/// which is how a sheet stops its own drag while a segment is in use. It cannot
/// work on the strip: `PagedTabBar` fills itself with a horizontal scroller
/// (`delaysContentTouches = false`), so touches land in that scroller and the
/// control's own tracking never begins. The actions would be wired,
/// correct-looking and silent.
///
/// ⚠️ AND IT MUST NOT SWALLOW WHAT IT WATCHES. `cancelsTouchesInView` is false
/// and the delegate recognises simultaneously, so the strip still scrolls and
/// still selects — this only observes. A recogniser added without both of those
/// silences the control it was meant to watch, which this codebase has already
/// paid for once: a tap with no action still prevents an ancestor's.
///
/// ⚠️ **IT COUNTS ITS WATCHED VIEWS, BECAUSE ONE PROBE CAN WATCH SEVERAL.**
/// Upload's editor toolbar carries two bars side by side and one probe attached
/// to both: with a bare flag, sliding a finger off one bar onto the other
/// announced `false` while a finger was still down, and the host — which
/// suspends the stack's back-swipe for the length of a touch — would have put
/// the back-swipe back underneath a live drag. The host is the wrong place to
/// fix that: it knows how many bars it attached, but not which of them a given
/// lift came from. Same shape as the `suspendedPans` slot that this editor's
/// crop mode already records as "ONE PREDICATE, TWO OWNERS".
@MainActor
public final class SelectorTouchProbe: NSObject, UIGestureRecognizerDelegate {
    /// `true` while a finger is on ANY watched view.
    private let onChange: (Bool) -> Void

    /// The probes with a finger currently down. Announcements happen only on the
    /// transitions into and out of empty — a second view being touched is not a
    /// second "a touch began".
    private var down: Set<ObjectIdentifier> = []

    public init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        super.init()
    }

    public func attach(to view: UIView) {
        let probe = UILongPressGestureRecognizer(target: self, action: #selector(changed))
        probe.minimumPressDuration = 0
        probe.cancelsTouchesInView = false
        probe.delaysTouchesBegan = false
        probe.delaysTouchesEnded = false
        probe.delegate = self
        view.addGestureRecognizer(probe)
    }

    @objc private func changed(_ probe: UILongPressGestureRecognizer) {
        switch probe.state {
        case .began, .changed:
            record(ObjectIdentifier(probe), isDown: true)
        case .ended, .cancelled, .failed:
            record(ObjectIdentifier(probe), isDown: false)
        default:
            break
        }
    }

    private func record(_ key: ObjectIdentifier, isDown: Bool) {
        let wasTouching = !down.isEmpty
        if isDown { down.insert(key) } else { down.remove(key) }
        let isTouching = !down.isEmpty
        guard isTouching != wasTouching else { return }
        onChange(isTouching)
    }

    /// ⚠️ ALWAYS TRUE, AND THAT IS WHAT KEEPS THE PROBE A PROBE. It exists to
    /// be TOLD about a touch, not to win it; refusing simultaneous recognition
    /// would make it compete with the strip's own scroller and its segment taps.
    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

#if DEBUG
extension SelectorTouchProbe {
    /// Internal for tests: the tally, entered where the recogniser enters it.
    ///
    /// ⚠️ **A GESTURE RECOGNISER'S STATE CANNOT BE SET.** `UIGestureRecognizer`
    /// vends `state` read-only, and no test can make a real finger land on one of
    /// two bars and lift from the other. What is NOT covered by this door is the
    /// three-line mapping from `state` to "down or up"; what is covered is the
    /// tally itself, which is where the defect was.
    func debugTouch(_ token: AnyObject, isDown: Bool) {
        record(ObjectIdentifier(token), isDown: isDown)
    }
}
#endif
