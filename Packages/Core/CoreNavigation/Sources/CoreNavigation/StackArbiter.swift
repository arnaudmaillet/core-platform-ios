import DesignSystem
import ObjectiveC
import UIKit

/// The one owner of a navigation stack's programmatic closes (#1144): a close
/// names the screen it closes, closes that screen only, and never twice.
///
/// ```
///   screen.closeScreen()          → navigationController.arbiter.close(screen)
///     not in the stack any more   → nothing (`.alreadyGone`)
///     on top, nothing running     → popViewController, pending until it lands
///     on top, a transition running→ asked again once it ends, if still there
///     below the top               → taken out alone; the screen above stays
///     our own pop still landing   → dropped (`.dropped`)
/// ```
///
/// ⚠️ **"NOTHING RUNNING" IS KNOWN ONE TURN LATE.** The transition coordinator
/// exists only from the run-loop turn after `popViewController` (measured,
/// `MapsViewController`), so two closes in one turn both saw none, and the
/// second popped the screen under the first. The arbiter sets its own
/// `isPending` at once, synchronously, and clears it when the coordinator's
/// transition completes.
///
/// ⚠️ **NEVER `popViewController()` FOR SOMEONE ELSE.** A pop after an
/// `await` (a block, a saved birth date) used to pop whatever was on top: a
/// screen the viewer had pushed meanwhile, or the one under their own back
/// swipe. A close here acts on its screen's identity.
///
/// It is not the stack's delegate — any navigation delegate removes the
/// full-surface back swipe on bar-hiding screens (PR #672) — and owns no
/// recognizer: the back gestures keep their own guards, and close through
/// `close(_:whenBusy: .drop)`. The back BUTTON closes through it on an
/// `ArbitratedNavigationController` (each screen's `backAction`). A sheet's
/// close is DesignSystem's `closePresentation()`; `StackCloseGuardTests`
/// keeps raw pops and dismisses out of the app.
@MainActor
public final class StackArbiter {
    public enum CloseResult: Equatable, Sendable {
        /// The screen is leaving, or has left.
        case closed
        /// It was not in the stack (any more), or is its root: nothing done.
        case alreadyGone
        /// Another close of this stack is still landing: nothing done.
        case dropped
        /// A transition is running; the close is asked again when it ends.
        case deferred
    }

    /// What a close does when a transition is running.
    public enum WhenBusy: Sendable {
        /// Asked again once it ends, if the screen is still there: a tap.
        case retry
        /// Nothing (`.dropped`): a gesture, which closes its screen now, from
        /// the top, or not at all — a grab begun during a transition must not
        /// pop after its release, nor take out a screen the viewer no longer
        /// sees.
        case drop
    }

    private weak var navigationController: UINavigationController?

    /// A close this arbiter issued and that has not landed yet.
    public private(set) var isPending = false

    init(_ navigationController: UINavigationController) {
        self.navigationController = navigationController
    }

    /// Closes `screen`, and only it.
    @discardableResult
    public func close(_ screen: UIViewController, animated: Bool = true, whenBusy: WhenBusy = .retry) -> CloseResult {
        guard let navigation = navigationController,
              let index = navigation.viewControllers.firstIndex(where: { $0 === screen }), index > 0 else {
            return .alreadyGone
        }
        guard !isPending else { return .dropped }
        let isTop = index == navigation.viewControllers.count - 1
        if !isTop, whenBusy == .drop { return .dropped }
        if isTop, let running = navigation.transitionCoordinator {
            guard whenBusy == .retry else { return .dropped }
            // The viewer's own back swipe, or a push still landing: asked again
            // once it has, only if the screen is still there.
            running.animate(alongsideTransition: nil) { [weak self, weak screen] _ in
                guard let self, let screen else { return }
                Task { @MainActor [weak self, weak screen] in
                    guard let self, let screen else { return }
                    close(screen, animated: animated)
                }
            }
            return .deferred
        }
        if isTop {
            isPending = true
            navigation.popViewController(animated: animated)
            settle(navigation)
        } else {
            // Below the top: taken out alone, without a transition — the
            // screen above is the viewer's and stays where it is.
            var stack = navigation.viewControllers
            stack.remove(at: index)
            navigation.setViewControllers(stack, animated: false)
        }
        return .closed
    }

    /// Clears `isPending` once the pop has landed: the coordinator appears on
    /// the next turn; none means it was not animated, and it is done.
    private func settle(_ navigation: UINavigationController) {
        Task { @MainActor [weak self, weak navigation] in
            guard let self else { return }
            guard let coordinator = navigation?.transitionCoordinator else {
                isPending = false
                return
            }
            coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                self?.isPending = false
            }
        }
    }
}

public extension UINavigationController {
    /// This stack's arbiter (#1144), made on first use.
    var arbiter: StackArbiter {
        if let existing = objc_getAssociatedObject(self, &StackArbiterKey.key) as? StackArbiter { return existing }
        let arbiter = StackArbiter(self)
        objc_setAssociatedObject(self, &StackArbiterKey.key, arbiter, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return arbiter
    }
}

private enum StackArbiterKey {
    nonisolated(unsafe) static var key: UInt8 = 0
}

public extension UIViewController {
    /// Closes THIS screen (#1144): popped from its stack through the stack's
    /// arbiter, or — the root of a presentation — dismissed, only while it is
    /// still the one presented. Nothing happens when it has already gone.
    @discardableResult
    func closeScreen(animated: Bool = true, whenBusy: StackArbiter.WhenBusy = .retry) -> StackArbiter.CloseResult {
        if let navigation = navigationController, navigation.viewControllers.first !== self {
            return navigation.arbiter.close(self, animated: animated, whenBusy: whenBusy)
        }
        return closePresentation(animated: animated) ? .closed : .alreadyGone
    }
}
