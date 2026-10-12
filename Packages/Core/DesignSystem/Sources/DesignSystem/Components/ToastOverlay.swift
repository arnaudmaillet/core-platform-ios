import UIKit

/// Where every toast of a scene is drawn (#954): a window of its own, above
/// the app's, so a toast outlives the screen it was fired from — a pop, a
/// dismissed sheet — and is never drawn under a sheet.
///
/// Until #954 a toast was a subview of the screen it answered: it left with
/// that screen (the profile's block confirmation had to be hosted on the
/// navigation controller's view so a pop would not take it away), and only
/// `Feedback`'s choice of host kept it out from under sheets.
///
/// ## A band, not the screen
///
/// The window spans from the foot of the status band to the FLOOR — the top
/// of whatever is lowest on screen (`floorY`) — never the status bar itself:
/// a full-screen window above the app's takes over the status bar's
/// appearance (the snap feed's light style), the trap `OfflineIndicator`
/// documents. Top toasts hang from the window's top edge, bottom toasts stand
/// on its bottom one, so the band's frame IS the placement.
///
/// ## The floor
///
/// The lowest of:
/// - the screen's floor `Feedback` measured when the toast was fired: the
///   host screen's safe area bottom — which clears its tab bar, its toolbar
///   and the tab accessory — or the top of a composer resting there;
/// - the keyboard's top, followed as it moves.
///
/// ## Touches
///
/// The window takes a touch only on a toast (`ToastOverlayWindow`); everywhere
/// else the app beneath gets it. It is hidden whenever it holds no toast, so
/// an idle window never answers UI tests' window queries or VoiceOver's touch
/// exploration.
///
/// ## Appearance and text size
///
/// It wears the app window's text-size ceiling and Care Mode weight, and the
/// style of the screen the toast answers, at every presentation
/// (`wearTraits(of:style:)`).
@MainActor
final class ToastOverlay {
    /// The overlay of `window`'s scene, made on first use — for the scene's
    /// KEY window only, the app's. Nil for any other window, where `Feedback`
    /// keeps drawing in the screen itself.
    ///
    /// ⚠️ NOT EVERY WINDOW IN A SCENE. A package test host gives the plain
    /// windows its tests make a scene too; one overlay per scene shared by
    /// suites running side by side would let one test's toast replace
    /// another's (one per position) and leave toasts behind for the next.
    /// Those windows are never key; the app's is.
    static func overlay(for window: UIWindow) -> ToastOverlay? {
        if let make = makeForTests { return make(window) }
        guard let scene = window.windowScene, window.isKeyWindow else { return nil }
        let key = ObjectIdentifier(scene)
        if let existing = overlays[key], existing.scene === scene {
            existing.appWindow = window
            return existing
        }
        let overlay = ToastOverlay(window: ToastOverlayWindow(windowScene: scene), appWindow: window)
        overlay.scene = scene
        overlays[key] = overlay
        return overlay
    }

    private static var overlays: [ObjectIdentifier: ToastOverlay] = [:]

    /// A test's overlay, built over a plain window (a package test host has
    /// no scene to give one). Set and restored synchronously by the test.
    static var makeForTests: ((UIWindow) -> ToastOverlay?)?

    private weak var scene: UIWindowScene?
    /// The window the toasts are drawn in.
    let window: UIWindow
    /// The app's window the toasts answer — its safe area and keyboard.
    private(set) weak var appWindow: UIWindow?
    /// The screen's floor, in `appWindow`'s coordinates (`refloor()`); nil:
    /// the window's own safe area bottom.
    private var screenFloorY: CGFloat?
    /// The screen's ceiling, in `appWindow`'s coordinates: the foot of its
    /// navigation bar — top toasts hang below the bar's buttons, not on them
    /// (#955: "Offline" sat on the wallet pill). Nil: the status band's foot.
    private var screenCeilingY: CGFloat?
    /// What the floor is measured from: the composer the latest toast was
    /// told to stand on, and the screen it was fired from — both weak: once
    /// they leave the window, the screen now on top is the floor.
    private weak var floorView: UIView?
    private weak var floorHost: UIViewController?
    /// Re-measures the floor every few frames while a toast is up — a pop
    /// under it brings another screen's chrome (a tab accessory) — and only
    /// then: nothing ticks while the overlay is idle (#580).
    private var floorLink: CADisplayLink?
    /// The keyboard's top, in `appWindow`'s coordinates, while it is up.
    private var keyboardTopY: CGFloat?
    /// Kept for the overlay's lifetime, which is its scene's: overlays are
    /// never released (`overlays`), so nothing removes them.
    private var observers: [NSObjectProtocol] = []

    init(window: UIWindow, appWindow: UIWindow) {
        self.window = window
        self.appWindow = appWindow
        window.windowLevel = .normal + 1
        window.backgroundColor = .clear
        let root = ToastOverlayRootController(appWindow: appWindow)
        root.view.backgroundColor = .clear
        // No safe area of its own to stand toasts on: the band's frame is the
        // placement, so its edges are where the toasts go.
        root.viewRespectsSystemMinimumLayoutMargins = false
        root.view.insetsLayoutMarginsFromSafeArea = false
        root.view.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 0, leading: Spacing.lg, bottom: 0, trailing: Spacing.lg
        )
        window.rootViewController = root
        window.isHidden = true
        observeKeyboard()
    }

    /// The view toasts are added to.
    var container: UIView { window.rootViewController!.view }

    /// The toasts on screen, oldest first.
    var toasts: [ToastView] { container.subviews.compactMap { $0 as? ToastView } }

    /// Shows a toast at `position`. `floorY` is the screen's floor and
    /// `keyboardTopY` the keyboard's top if it is up, both in the app
    /// window's coordinates (nil floor: its safe area bottom).
    ///
    /// The band is shared: the latest toast's screen sets the floor every
    /// bottom toast stands on.
    func present(
        _ message: String,
        detail: String? = nil,
        symbol: String?,
        style: ToastView.Style,
        action: ToastView.Action? = nil,
        undoable: ToastView.Undoable? = nil,
        id: String? = nil,
        isCondition: Bool = false,
        position: ToastPosition,
        from host: UIViewController?,
        above floor: UIView?,
        keyboardTopY: CGFloat? = nil,
        interfaceStyle: UIUserInterfaceStyle = .unspecified
    ) -> ToastView {
        if let appWindow { wearTraits(of: appWindow, style: interfaceStyle) }
        // The screen that shows, not its container: a stack's safe area holds
        // neither its navigation bar nor the tab accessory (a toast fired
        // from a tab shell sat on the inbox's wallet pill).
        floorHost = host.map(Self.visibleScreen(in:))
        floorView = floor
        self.keyboardTopY = keyboardTopY
        screenFloorY = measuredFloorY()
        screenCeilingY = measuredCeilingY()
        placeBand()
        followFloor()
        window.isHidden = false
        window.layoutIfNeeded()
        let toast = ToastView.present(
            message, detail: detail, symbol: symbol, style: style, action: action, undoable: undoable,
            id: id, isCondition: isCondition, position: position, in: container,
            edge: position.isTop ? container.topAnchor : container.bottomAnchor
        )
        toast.onRemoved = { [weak self] in self?.hideIfEmpty() }
        // ⚠️ AGAIN, AFTER: the toast this one replaced left inside
        // `ToastView.present`, before this one was added — the window was
        // empty for that instant and hid itself, and stopped following the
        // floor. A second toast at the same position showed nothing.
        window.isHidden = false
        followFloor()
        return toast
    }

    /// The app window's text-size ceiling and Care Mode weight — what
    /// `CareModePreference` sets on it — copied, and the style of the screen
    /// the toast answers (`style`; unspecified: the app window's), so a toast
    /// reads like the screen under it: dark glass over the snap feed's
    /// photographs, which pins its own style.
    private func wearTraits(of appWindow: UIWindow, style: UIUserInterfaceStyle) {
        window.overrideUserInterfaceStyle = style == .unspecified ? appWindow.overrideUserInterfaceStyle : style
        let overrides = appWindow.traitOverrides
        if overrides.contains(UITraitPreferredContentSizeCategory.self) {
            window.traitOverrides.preferredContentSizeCategory = overrides.preferredContentSizeCategory
        } else {
            window.traitOverrides.remove(UITraitPreferredContentSizeCategory.self)
        }
        if overrides.contains(UITraitLegibilityWeight.self) {
            window.traitOverrides.legibilityWeight = overrides.legibilityWeight
        } else {
            window.traitOverrides.remove(UITraitLegibilityWeight.self)
        }
    }

    // MARK: - The band

    /// The band's frame in the app window's coordinates: from the foot of the
    /// status band to the floor (`ToastOverlay` doc).
    static func band(
        in bounds: CGRect, safeArea: UIEdgeInsets, screenFloorY: CGFloat?, keyboardTopY: CGFloat?,
        screenCeilingY: CGFloat? = nil
    ) -> CGRect {
        let top = max(bounds.minY + safeArea.top, screenCeilingY ?? -.infinity)
        var floor = screenFloorY ?? (bounds.maxY - safeArea.bottom)
        if let keyboardTopY { floor = min(floor, keyboardTopY) }
        floor = min(max(floor, top), bounds.maxY)
        return CGRect(x: bounds.minX, y: top, width: bounds.width, height: floor - top)
    }

    /// Where the band goes now, in the scene's coordinates.
    private func bandFrame() -> CGRect? {
        guard let appWindow else { return nil }
        let band = Self.band(
            in: appWindow.bounds, safeArea: appWindow.safeAreaInsets,
            screenFloorY: screenFloorY, keyboardTopY: keyboardTopY, screenCeilingY: screenCeilingY
        )
        // Both windows share the scene's coordinate space.
        return band.offsetBy(dx: appWindow.frame.minX, dy: appWindow.frame.minY)
    }

    private func placeBand() {
        guard let frame = bandFrame(), window.frame != frame else { return }
        window.frame = frame
    }

    private func hideIfEmpty() {
        guard toasts.isEmpty else { return }
        window.isHidden = true
        floorLink?.invalidate()
        floorLink = nil
        screenFloorY = nil
        screenCeilingY = nil
    }

    // MARK: - The floor

    /// The floor now: the composer if it is still in the window, else the
    /// screen the toast was fired from, else the screen now on top of the app
    /// window (`Feedback.host`) — the one a pop or a dismissal left showing.
    func measuredFloorY() -> CGFloat? {
        guard let appWindow else { return nil }
        if let floorView, floorView.window === appWindow {
            return Feedback.floorY(of: nil, above: floorView, in: appWindow)
        }
        if let floorHost, floorHost.viewIfLoaded?.window === appWindow {
            return Feedback.floorY(of: floorHost, above: nil, in: appWindow)
        }
        guard let root = appWindow.rootViewController else { return nil }
        let top = Self.visibleScreen(in: Feedback.host(for: root))
        guard top.viewIfLoaded?.window === appWindow else { return nil }
        floorHost = top
        return Feedback.floorY(of: top, above: nil, in: appWindow)
    }

    /// The ceiling now: under the navigation bar of the screen the floor is
    /// measured from (`measuredFloorY` settles which) — its safe area top, or
    /// the bar's own foot when that is lower: a screen that runs its content
    /// under a bare bar (the inbox) does not count the bar in its safe area.
    func measuredCeilingY() -> CGFloat? {
        guard let appWindow, let host = floorHost, let view = host.viewIfLoaded, view.window === appWindow else {
            return nil
        }
        var ceiling = view.convert(view.safeAreaLayoutGuide.layoutFrame, to: appWindow).minY
        if let stack = host.navigationController, !stack.isNavigationBarHidden,
           stack.navigationBar.window === appWindow, !stack.navigationBar.isHidden {
            let bar = stack.navigationBar
            ceiling = max(ceiling, bar.convert(bar.bounds, to: appWindow).maxY)
        }
        return ceiling
    }

    /// The screen a container shows: a stack's top, a tab shell's selected
    /// tab, all the way down — the one whose safe area holds that screen's
    /// own chrome (a tab accessory belongs to it, not to its stack).
    static func visibleScreen(in controller: UIViewController) -> UIViewController {
        var screen = controller
        while true {
            if let stack = screen as? UINavigationController, let top = stack.topViewController {
                screen = top
            } else if let tabs = screen as? UITabBarController, let selected = tabs.selectedViewController {
                screen = selected
            } else if let child = largestVisibleChild(of: screen) {
                // Any other container — the notifications drawer's, around
                // the tab shell: into the child that fills the screen.
                screen = child
            } else {
                return screen
            }
        }
    }

    /// The child of a custom container covering most of its window, if any
    /// covers most of the container — a leaf screen's own small children
    /// (a pager's page, a header) are not "the screen".
    private static func largestVisibleChild(of container: UIViewController) -> UIViewController? {
        guard let window = container.viewIfLoaded?.window else { return nil }
        let containerArea = area(of: container.view, in: window)
        guard containerArea > 0 else { return nil }
        let best = container.children
            .filter { $0.viewIfLoaded?.window === window && !$0.view.isHidden }
            .map { ($0, area(of: $0.view, in: window)) }
            .max { $0.1 < $1.1 }
        guard let best, best.1 >= containerArea * 0.9 else { return nil }
        return best.0
    }

    private static func area(of view: UIView, in window: UIWindow) -> CGFloat {
        let visible = view.convert(view.bounds, to: window).intersection(window.bounds)
        return visible.isNull ? 0 : visible.width * visible.height
    }

    /// Measures the floor again and moves the band if it moved — or if the
    /// app window itself changed (a rotation, a new safe area). A floor that
    /// cannot be measured right now — mid-transition, no screen of the app's
    /// in the window — keeps the last one: falling back to the window's safe
    /// area would drop the toasts onto the tab bar for a frame.
    func refloor(animated: Bool = true) {
        if let floor = measuredFloorY() { screenFloorY = floor }
        if let ceiling = measuredCeilingY() { screenCeilingY = ceiling }
        guard let target = bandFrame(), abs(target.minY - window.frame.minY) > 0.5
            || abs(target.height - window.frame.height) > 0.5 || abs(target.width - window.frame.width) > 0.5
        else { return }
        guard animated, !window.isHidden else {
            placeBand()
            return
        }
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut]) {
            self.placeBand()
            self.window.layoutIfNeeded()
        }
    }

    private func followFloor() {
        guard floorLink == nil else { return }
        let link = CADisplayLink(target: FloorTick(self), selector: #selector(FloorTick.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 20, preferred: 15)
        link.add(to: .main, forMode: .common)
        floorLink = link
    }

    /// The display link's target: it holds the overlay weakly (a link
    /// retains its target), and runs on the main run loop.
    @MainActor
    private final class FloorTick: NSObject {
        weak var overlay: ToastOverlay?
        init(_ overlay: ToastOverlay) { self.overlay = overlay }
        @objc func tick() { overlay?.refloor() }
    }

    // MARK: - The keyboard

    private func observeKeyboard() {
        let center = NotificationCenter.default
        for (name, hiding) in [
            (UIResponder.keyboardWillChangeFrameNotification, false),
            (UIResponder.keyboardWillHideNotification, true),
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
                let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
                MainActor.assumeIsolated {
                    self?.keyboardWillChange(endFrame: end, duration: duration, hiding: hiding)
                }
            })
        }
    }

    private func keyboardWillChange(endFrame end: CGRect?, duration: Double, hiding: Bool) {
        guard let appWindow, let end else { return }
        let frame = appWindow.convert(end, from: appWindow.screen.coordinateSpace)
        // A keyboard that is off screen, or floats clear of the bottom edge
        // (iPad's floating one), is no floor.
        keyboardTopY = !hiding && frame.intersects(appWindow.bounds) && frame.maxY >= appWindow.bounds.maxY - 1
            ? frame.minY : nil
        guard !window.isHidden else { return }
        UIView.animate(withDuration: duration, delay: 0, options: [.beginFromCurrentState]) {
            self.placeBand()
            self.window.layoutIfNeeded()
        }
    }
}

/// The overlay's window: it takes a touch only on a toast, and never becomes
/// the key window.
///
/// ⚠️ NEVER KEY. A window that takes a touch becomes key by default: a tap on
/// a toast's Retry made the overlay key, the app's window stopped being it,
/// and the toast that Retry fired went to `Feedback`'s in-screen fallback
/// (`ToastOverlay.overlay(for:)` serves the key window only) — and the
/// keyboard's first responder lives in the key window too.
final class ToastOverlayWindow: UIWindow {
    override var canBecomeKey: Bool { false }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        guard let hit, hit !== self, hit !== rootViewController?.view else { return nil }
        return hit
    }
}

/// The overlay window's root: it never votes on what the app's own window
/// decides — the interface orientations and the status bar — and hands every
/// question back to the app window's root.
private final class ToastOverlayRootController: UIViewController {
    private weak var appWindow: UIWindow?

    init(appWindow: UIWindow) {
        self.appWindow = appWindow
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var appRoot: UIViewController? { appWindow?.rootViewController }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        appRoot?.supportedInterfaceOrientations ?? super.supportedInterfaceOrientations
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        appRoot?.preferredStatusBarStyle ?? super.preferredStatusBarStyle
    }

    override var prefersStatusBarHidden: Bool {
        appRoot?.prefersStatusBarHidden ?? super.prefersStatusBarHidden
    }
}
