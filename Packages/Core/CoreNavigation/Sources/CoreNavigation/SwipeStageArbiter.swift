import UIKit

/// Which way a horizontal drag goes.
public enum SwipeDirection: Sendable, Equatable {
    /// Towards the leading edge: the finger moves left (in left-to-right).
    case leftward
    /// Towards the trailing edge.
    case rightward
}

/// A panel a horizontal drag opens or closes, driven by the finger — the
/// snap feed's side list (#1425). The arbiter hands it the drag it picked.
@MainActor
public protocol SwipePanel: AnyObject {
    func panelDragDidBegin()
    /// The drag's horizontal translation since it began, in points.
    func panelDragDidChange(translationX: CGFloat)
    /// The release, with its horizontal speed in points per second.
    func panelDragDidEnd(velocityX: CGFloat)
    func panelDragDidCancel()
}

/// What a horizontal drag on a screen does (#1525): one stage of the screen's
/// chain. The content's own horizontal scroll (a carousel) comes first and is
/// the screen's to decline (it answers no stage); then a panel; then a push.
@MainActor
public enum SwipeStage {
    /// Opens or closes a panel, following the finger.
    case panel(any SwipePanel)
    /// Pushes the screen this makes onto the screen's own stack, following
    /// the finger (`InteractivePushDriver`). Nil from the closure: nothing to
    /// push after all.
    case push(() -> UIViewController?)
}

/// The screen a `SwipeStageArbiter` serves: it declares, for a drag born at a
/// point, the stage that takes it — or none (the content keeps the drag, or
/// another gesture owns that direction).
@MainActor
public protocol SwipeStageHosting: AnyObject {
    /// The stage for a horizontal drag going `direction`, born at `origin`
    /// (in the arbiter's view). Nil: the arbiter's pan does not begin.
    func swipeStage(for direction: SwipeDirection, at origin: CGPoint) -> SwipeStage?
    /// The stack a `.push` goes onto.
    var swipeNavigationController: UINavigationController? { get }
    /// A push stage is about to start: freeze what must not move under it.
    func swipePushWillBegin()
    /// A push stage ended: committed (the screen is on the stack) or not.
    func swipePushDidEnd(committed: Bool)
}

public extension SwipeStageHosting {
    func swipePushWillBegin() {}
}

/// One pan for a screen's horizontal swipe chain (#1525): it asks the screen
/// which stage takes the drag when it begins, then hands every event to that
/// stage — a panel's driver, or an interactive push. A screen declares its
/// stages and writes no gesture code; any destination can hang on a swipe.
@MainActor
public final class SwipeStageArbiter: NSObject, UIGestureRecognizerDelegate {
    public let pan = UIPanGestureRecognizer()
    private weak var host: (any SwipeStageHosting)?
    private weak var view: UIView?
    /// The stage picked when the pan was allowed to begin.
    private var pending: SwipeStage?
    /// The stage driving the drag now.
    private var active: Active?
    private let pushDriver = InteractivePushDriver()

    private enum Active {
        case panel(any SwipePanel)
        case push
    }

    public init(host: any SwipeStageHosting) {
        self.host = host
        super.init()
        pan.addTarget(self, action: #selector(handlePan(_:)))
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        pushDriver.onFinish = { [weak self] committed in
            self?.host?.swipePushDidEnd(committed: committed)
        }
    }

    /// Puts the pan on `view`, the screen's.
    public func install(in view: UIView) {
        self.view = view
        view.addGestureRecognizer(pan)
    }

    /// Whether a push is running.
    public var isPushing: Bool { pushDriver.isPushing }

    // MARK: - Gesture

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan, let view, let host, active == nil, !pushDriver.isPushing else { return false }
        let velocity = pan.velocity(in: view)
        guard abs(velocity.x) > abs(velocity.y), velocity.x != 0 else { return false }
        let origin = CGPoint(
            x: pan.location(in: view).x - pan.translation(in: view).x,
            y: pan.location(in: view).y - pan.translation(in: view).y
        )
        let direction = Self.direction(ofVelocityX: velocity.x, in: view)
        pending = host.swipeStage(for: direction, at: origin)
        return pending != nil
    }

    /// Alongside everything else: the stages decline what they do not own
    /// (`swipeStage`), and the screen freezes what must not move with them.
    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        guard let view else { return }
        switch pan.state {
        case .began:
            begin(width: view.bounds.width)
        case .changed:
            change(translationX: pan.translation(in: view).x, width: view.bounds.width)
        case .ended:
            end(translationX: pan.translation(in: view).x, velocityX: pan.velocity(in: view).x, width: view.bounds.width)
        case .cancelled, .failed:
            cancel()
        default:
            break
        }
    }

    /// Leftward in the reading direction's terms: a right-to-left layout
    /// mirrors it.
    static func direction(ofVelocityX velocityX: CGFloat, in view: UIView) -> SwipeDirection {
        let leftward = view.effectiveUserInterfaceLayoutDirection == .rightToLeft ? velocityX > 0 : velocityX < 0
        return leftward ? .leftward : .rightward
    }

    // MARK: - Driving (internal for tests)

    func begin(width: CGFloat) {
        guard let stage = pending else { return }
        pending = nil
        switch stage {
        case .panel(let panel):
            active = .panel(panel)
            panel.panelDragDidBegin()
        case .push(let make):
            guard let navigation = host?.swipeNavigationController, let screen = make() else { return }
            host?.swipePushWillBegin()
            guard pushDriver.begin(pushing: screen, on: navigation) else {
                host?.swipePushDidEnd(committed: false)
                return
            }
            active = .push
        }
    }

    func change(translationX: CGFloat, width: CGFloat) {
        switch active {
        case .panel(let panel):
            panel.panelDragDidChange(translationX: translationX)
        case .push:
            pushDriver.update(progress: Self.pushProgress(translationX: translationX, width: width))
        case nil:
            break
        }
    }

    func end(translationX: CGFloat, velocityX: CGFloat, width: CGFloat) {
        defer { active = nil }
        switch active {
        case .panel(let panel):
            panel.panelDragDidEnd(velocityX: velocityX)
        case .push:
            pushDriver.end(
                progress: Self.pushProgress(translationX: translationX, width: width),
                velocity: width > 0 ? -velocityX / width : 0
            )
        case nil:
            break
        }
    }

    func cancel() {
        defer { active = nil }
        switch active {
        case .panel(let panel):
            panel.panelDragDidCancel()
        case .push:
            pushDriver.cancel()
        case nil:
            break
        }
    }

    /// A leftward drag's push progress: its travel over the width.
    nonisolated static func pushProgress(translationX: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        return min(max(-translationX / width, 0), 1)
    }

    #if DEBUG
    /// Picks `stage` as `gestureRecognizerShouldBegin` would. Tests.
    func debugPick(_ stage: SwipeStage?) { pending = stage }
    var debugIsActive: Bool { active != nil }
    var debugPushDriver: InteractivePushDriver { pushDriver }
    #endif
}
