import UIKit

/// ⚠️ A PULL PAST EITHER END OF THE LIST CLOSES IT (#1580, the owner
/// 2026-10-22): with the side list open, the card on the list's FIRST post
/// pulled down, or on its LAST post pulled up — where the pager has nothing
/// to page to — closes the list exactly as the rightward swipe does: driven
/// by the drag point for point, released on the same rule.
///
/// ⚠️ ITS OWN PAN, WHICH THE PAGER WAITS ON — not the pager's overscroll.
/// Read off the pager, the card itself would rubber-band past its end while
/// the list closed, and holding it still meant fighting UIKit's deceleration
/// on every frame. This pan fails at once whenever it does not apply — the
/// list closed or moving, the card on a middle post, a drag the other way or
/// sideways — so the pager's own scrolling is untouched.
@MainActor
final class SnapSideListEdgePull: NSObject, UIGestureRecognizerDelegate {
    /// The pulls that close the list right now.
    struct Directions: OptionSet {
        let rawValue: Int
        /// On the list's first post.
        static let down = Directions(rawValue: 1 << 0)
        /// On the list's last post.
        static let up = Directions(rawValue: 1 << 1)
    }

    private weak var host: SnapFeedViewController?
    private(set) var pan: UIPanGestureRecognizer!
    /// The direction this pull started in: +1 down, −1 up.
    private var sign: CGFloat = 1

    init(host: SnapFeedViewController) {
        self.host = host
        super.init()
        pan = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
    }

    func install(in view: UIView, pager: UIScrollView) {
        view.addGestureRecognizer(pan)
        pager.panGestureRecognizer.require(toFail: pan)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let host, let view = pan.view,
              let direction = Self.direction(of: pan.velocity(in: view), allowed: host.sideListEdgePulls)
        else { return false }
        sign = direction == .down ? 1 : -1
        return true
    }

    /// The pull a drag at `velocity` is, among `allowed`: vertical first,
    /// then the way it goes. Nil: not a closing pull.
    nonisolated static func direction(of velocity: CGPoint, allowed: Directions) -> Directions? {
        guard abs(velocity.y) > abs(velocity.x), velocity.y != 0 else { return nil }
        let pull: Directions = velocity.y > 0 ? .down : .up
        return allowed.contains(pull) ? pull : nil
    }

    @objc private func handle(_ pan: UIPanGestureRecognizer) {
        guard let panel = host?.sideList, let view = pan.view else { return }
        switch pan.state {
        case .began:
            panel.panelDragDidBegin()
        case .changed:
            // Toward its end closes as rightward does: the same travel.
            panel.panelDragDidChange(translationX: max(0, sign * pan.translation(in: view).y))
        case .ended:
            panel.panelDragDidEnd(velocityX: sign * pan.velocity(in: view).y)
        case .cancelled, .failed:
            panel.panelDragDidCancel()
        default:
            break
        }
    }
}
