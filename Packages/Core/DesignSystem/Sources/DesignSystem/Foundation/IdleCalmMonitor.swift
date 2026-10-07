import UIKit

/// Rests the app's decoration once nobody has touched it for
/// `IdleCalm.after`, and wakes it on the next touch (#580).
///
/// What counts as a touch: any finger landing anywhere in a watched window,
/// a key pressed on a hardware keyboard, and any text typed — the software
/// keyboard lives in a window of its own, so typing a long message would
/// otherwise read as rest. The app coming back to the foreground wakes it
/// too.
@MainActor
public final class IdleCalmMonitor {
    public static let shared = IdleCalmMonitor()

    /// How long without a touch before decoration rests.
    var restsAfter: TimeInterval = IdleCalm.after
    /// Rests or wakes the app. Swappable for tests, which must not flip the
    /// app-wide state under suites running beside them.
    var apply: (Bool) -> Void = { IdleCalm.set($0) }
    /// Runs `deadline` after `delay`. Swappable for tests, which fire the
    /// deadlines themselves rather than racing real time: on a starved
    /// runner a test's own steps run late, and a real clock then expires
    /// between two "touches" that were meant to be close together.
    var schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, deadline in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated { deadline() }
        }
    }

    /// Bumped by every touch: a deadline set before the latest touch finds
    /// the count moved on and does nothing.
    private var touches = 0
    private var observers: [any NSObjectProtocol] = []
    private(set) var isResting = false

    init() {}

    /// Watches `window`'s touches and the app's typing, and starts the clock.
    public func install(on window: UIWindow) {
        window.addGestureRecognizer(IdleTouchWatcher { [weak self] in self?.touched() })
        if observers.isEmpty {
            let center = NotificationCenter.default
            observers = [
                UITextField.textDidChangeNotification,
                UITextView.textDidChangeNotification,
                UIApplication.willEnterForegroundNotification,
            ].map { name in
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.touched() }
                }
            }
        }
        touched()
    }

    /// Someone is here: decoration wakes, and the clock starts again.
    func touched() {
        if isResting {
            isResting = false
            apply(false)
        }
        touches += 1
        let touch = touches
        schedule(restsAfter) { [weak self] in self?.deadlinePassed(since: touch) }
    }

    /// `restsAfter` has passed since touch number `touch`: decoration rests,
    /// unless a later touch came in the meantime.
    private func deadlinePassed(since touch: Int) {
        guard touch == touches, !isResting else { return }
        isResting = true
        apply(true)
    }
}

/// Sees every touch a window receives and claims none of them: it fails on
/// the first one, so it never delays, cancels or competes with the gestures
/// underneath.
final class IdleTouchWatcher: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private let onTouch: () -> Void

    init(onTouch: @escaping () -> Void) {
        self.onTouch = onTouch
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouch()
        state = .failed
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        onTouch()
        super.pressesBegan(presses, with: event)
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool { true }
}
