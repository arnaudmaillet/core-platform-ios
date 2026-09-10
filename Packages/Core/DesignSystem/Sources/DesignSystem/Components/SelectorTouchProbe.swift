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
@MainActor
public final class SelectorTouchProbe: NSObject, UIGestureRecognizerDelegate {
    /// `true` while a finger is on the watched view.
    private let onChange: (Bool) -> Void

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
            onChange(true)
        case .ended, .cancelled, .failed:
            onChange(false)
        default:
            break
        }
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
