import UIKit

/// Where every toast of a scene is drawn (#954, the only host since #2143): a
/// window of its own, above the app's, so a toast outlives the screen it was
/// fired from — a pop, a dismissed sheet, a tab switch — and is never drawn
/// under a sheet or lost in a bar.
///
/// ## One place: under the top bar of the screen in view
///
/// Every toast hangs `ToastView.Metrics.topGap` under the anchor
/// (`ToastAnchor`): the navigation bar of the screen in view, its own top
/// chrome, or the status bar. It never takes a bar item's place, so the
/// bell, Follow and back stay tappable while it is up.
///
/// ## It follows its anchor
///
/// While a toast is up, the anchor is read again on every frame
/// (`follow(animated:)`), and the toasts move with it through the
/// container's `ceiling` — layout, never a transform on glass:
/// - a step a frame can take (a large title collapsing under the finger):
///   at once, frame by frame;
/// - a bigger one (a push or a pop to a bar of another height, a detent, a
///   rotation): animated alongside the change;
/// - a jump of more than `farAway` (opening the full-screen feed from a
///   list): a quick cross-fade to the new place, never a slide across the
///   screen.
///
/// The link ticks at the display's rate while the anchor moves and slows
/// down once it has been still a moment; nothing ticks while the overlay is
/// idle (#580).
///
/// ## A band, not the screen
///
/// The window spans from the foot of the status band to the app window's
/// safe area bottom — never the status bar itself: a full-screen window above
/// the app's takes over the status bar's appearance (the snap feed's light
/// style), the trap `OfflineIndicator` documents.
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
    /// another's and leave toasts behind for the next. Those windows are
    /// never key; the app's is.
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

    /// A move of the anchor this small is followed at once — a frame's step
    /// under the finger; a bigger one is animated.
    static let trackedStep: CGFloat = 12
    /// A move of the anchor further than this is a cross-fade, not a slide:
    /// more than a large title's height.
    static let farAway: CGFloat = 72
    /// How long the anchor stays still before the link slows down.
    static let restAfter: CFTimeInterval = 0.5

    private weak var scene: UIWindowScene?
    /// The window the toasts are drawn in.
    let window: UIWindow
    /// The app's window the toasts answer — its screens and safe area.
    private(set) weak var appWindow: UIWindow?
    /// What the toasts hang from: the anchor's foot, in the container.
    let ceiling = UILayoutGuide()
    private let ceilingHeight: NSLayoutConstraint
    /// Reads the anchor every frame while a toast is up, and only then.
    private var followLink: CADisplayLink?
    /// When the anchor last moved: the link runs fast until it has been
    /// still for `restAfter`.
    private var lastMove: CFTimeInterval = 0
    private var isFollowingFast = false

    init(window: UIWindow, appWindow: UIWindow) {
        self.window = window
        self.appWindow = appWindow
        window.windowLevel = .normal + 1
        window.backgroundColor = .clear
        let root = ToastOverlayRootController(appWindow: appWindow)
        root.view.backgroundColor = .clear
        // No safe area of its own: the band's frame and the ceiling are the
        // placement.
        root.viewRespectsSystemMinimumLayoutMargins = false
        root.view.insetsLayoutMarginsFromSafeArea = false
        root.view.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 0, leading: Spacing.lg, bottom: 0, trailing: Spacing.lg
        )
        window.rootViewController = root
        root.view.addLayoutGuide(ceiling)
        ceilingHeight = ceiling.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            ceiling.topAnchor.constraint(equalTo: root.view.topAnchor),
            ceiling.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
            ceiling.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
            ceilingHeight,
        ])
        window.isHidden = true
    }

    /// The view toasts are added to.
    var container: UIView { window.rootViewController!.view }

    /// The toasts on screen, oldest first.
    var toasts: [ToastView] { container.subviews.compactMap { $0 as? ToastView } }

    /// The anchor's foot the toasts hang under now, in the app window's
    /// coordinates.
    var placedAnchorY: CGFloat { window.frame.minY - (appWindow?.frame.minY ?? 0) + ceilingHeight.constant }

    /// Shows a toast under the anchor of the screen in view.
    func present(
        _ message: String,
        symbol: String?,
        style: ToastView.Style,
        action: ToastView.Action? = nil,
        undoable: ToastView.Undoable? = nil,
        id: String? = nil,
        isCondition: Bool = false,
        length: ToastView.Length = .standard,
        interfaceStyle: UIUserInterfaceStyle = .unspecified
    ) -> ToastView {
        if let appWindow { wearTraits(of: appWindow, style: interfaceStyle) }
        // A first toast lands where the anchor is; one joining a toast
        // already up moves them all, as the anchor's move would.
        follow(animated: !window.isHidden)
        window.isHidden = false
        window.layoutIfNeeded()
        let toast = ToastView.present(
            message, symbol: symbol, style: style, action: action, undoable: undoable,
            id: id, isCondition: isCondition, length: length, in: container, ceiling: ceiling.bottomAnchor
        )
        // ⚠️ ON THE NEXT TURN, NOT AT ONCE (filmed, 2026-11-06): a toast
        // taking over another's capsule removes it before it is added
        // itself, and a window hidden and shown again in one turn missed a
        // whole frame — the toast blinked out on a fast toggle.
        toast.onRemoved = { [weak self] in
            DispatchQueue.main.async { self?.hideIfEmpty() }
        }
        // ⚠️ AGAIN, AFTER: the toast this one replaced may have left inside
        // `ToastView.present`, before this one was added.
        window.isHidden = false
        startFollowing()
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
    /// status band to the safe area bottom.
    static func band(in bounds: CGRect, safeArea: UIEdgeInsets) -> CGRect {
        let top = bounds.minY + safeArea.top
        let bottom = max(top, bounds.maxY - safeArea.bottom)
        return CGRect(x: bounds.minX, y: top, width: bounds.width, height: bottom - top)
    }

    /// Where the band goes now, in the scene's coordinates.
    private func bandFrame() -> CGRect? {
        guard let appWindow else { return nil }
        let band = Self.band(in: appWindow.bounds, safeArea: appWindow.safeAreaInsets)
        // Both windows share the scene's coordinate space.
        return band.offsetBy(dx: appWindow.frame.minX, dy: appWindow.frame.minY)
    }

    private func hideIfEmpty() {
        guard toasts.isEmpty else { return }
        window.isHidden = true
        followLink?.invalidate()
        followLink = nil
    }

    // MARK: - Following the anchor

    /// Reads the anchor again and moves the toasts to it (see the type doc):
    /// at once, animated, or through a cross-fade, by how far it went. A
    /// rotation or a new safe area moves the band first.
    func follow(animated: Bool = true) {
        guard let appWindow, let band = bandFrame() else { return }
        let bandMoved = window.frame != band
        if bandMoved { window.frame = band }
        let anchor = ToastAnchor.anchorY(in: appWindow)
        let height = max(0, anchor - (band.minY - appWindow.frame.minY))
        let distance = abs(height - ceilingHeight.constant)
        guard distance > 0.5 else {
            if bandMoved { container.layoutIfNeeded() }
            return
        }
        lastMove = CACurrentMediaTime()
        ceilingHeight.constant = height
        let moving = toasts.filter { !$0.isDismissing }
        if !animated || window.isHidden || moving.isEmpty || distance <= Self.trackedStep {
            container.layoutIfNeeded()
        } else if distance > Self.farAway {
            ToastView.crossFade(moving, in: container)
        } else {
            UIView.animate(
                withDuration: 0.35, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0,
                options: [.beginFromCurrentState, .allowUserInteraction]
            ) {
                self.container.layoutIfNeeded()
            }
        }
    }

    private func startFollowing() {
        guard followLink == nil else { return }
        let link = CADisplayLink(target: FollowTick(self), selector: #selector(FollowTick.tick))
        link.preferredFrameRateRange = Self.restingRate
        link.add(to: .main, forMode: .common)
        followLink = link
        isFollowingFast = false
        lastMove = CACurrentMediaTime()
        paceLink()
    }

    private static let restingRate = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 10)
    private static let movingRate = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)

    /// Fast while the anchor moves, slow once it has rested.
    private func paceLink() {
        guard let followLink else { return }
        let fast = CACurrentMediaTime() - lastMove < Self.restAfter
        guard fast != isFollowingFast else { return }
        isFollowingFast = fast
        followLink.preferredFrameRateRange = fast ? Self.movingRate : Self.restingRate
    }

    fileprivate func tick() {
        // The app window gone (a test host's window, released), there is
        // nothing to follow: the link stops, and the next toast starts it.
        guard appWindow != nil else {
            followLink?.invalidate()
            followLink = nil
            return
        }
        follow()
        paceLink()
    }

    /// The display link's target: it holds the overlay weakly (a link
    /// retains its target), and runs on the main run loop.
    @MainActor
    private final class FollowTick: NSObject {
        weak var overlay: ToastOverlay?
        init(_ overlay: ToastOverlay) { self.overlay = overlay }
        @objc func tick() { overlay?.tick() }
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
final class ToastOverlayWindow: AppWindow {
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
