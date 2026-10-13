import UIKit

/// The app's ONE way to answer an action with a toast (#804): what happened,
/// in the right place, with the right feel.
///
/// Before this, `ToastView.present` had twenty callers and each one guessed
/// its host. The guesses went wrong in the same three ways:
/// - **Under a sheet.** A toast posted onto the screen a sheet covers is drawn
///   behind the sheet: the user is told nothing. `Feedback` resolves the host
///   as the TOPMOST PRESENTED screen in the source's window, so a toast fired
///   from under a sheet shows above it.
/// - **No failure style.** A failure looked exactly like a success, with a
///   different glyph the eye does not read. `failure` tints its glyph red.
/// - **No haptic.** A toast is for results that are off-screen or easy to
///   miss, which is exactly when the hand should feel the answer too. Each
///   kind pairs its notification haptic, through `HapticNotification`, so the
///   Haptics switch (#470) is honoured.
///
/// Wording (the toast's own rule): short, past tense for a result, no
/// trailing period — "Copied", "Report sent", "Couldn't follow @ava".
///
/// ⚠️ NEVER CALL `ToastView.present` DIRECTLY. `FeedbackTests` scans the
/// sources and fails if anything but this file does: a presenter honoured by
/// nineteen call sites and bypassed by the twentieth is back to guessing.
@MainActor
public enum Feedback {
    /// What a toast reports. Each kind owns its toast style and its haptic.
    public enum Kind: Sendable {
        /// The action happened.
        case success
        /// The action did not happen — rolled back, refused, or failed.
        case failure
        /// Neither: a neutral notice ("Hidden from this feed"). No haptic —
        /// nothing succeeded or failed, so the hand has nothing to learn.
        case info
        /// It happened with a catch the viewer should know (#954): an orange
        /// glyph and a warning haptic.
        case warning
        /// Under way (#954): a spinner, until the same `id` says how it ended.
        case loading

        var style: ToastView.Style {
            switch self {
            case .success, .info: .confirmation
            case .failure: .failure
            case .warning: .warning
            case .loading: .loading
            }
        }

        /// The notification haptic the toast arrives with, if any.
        public var haptic: UINotificationFeedbackGenerator.FeedbackType? {
            switch self {
            case .success: .success
            case .failure: .error
            case .info, .loading: nil
            case .warning: .warning
            }
        }

        /// The glyph a toast of this kind leads with unless told otherwise.
        public var defaultSymbol: String {
            switch self {
            case .success: "checkmark.circle.fill"
            case .failure: "exclamationmark.triangle.fill"
            case .info: "info.circle.fill"
            case .warning: "exclamationmark.circle.fill"
            case .loading: "ellipsis"
            }
        }
    }

    /// The action happened: a confirmation toast and a success haptic.
    ///
    /// - Parameters:
    ///   - source: the screen the action was taken on. The toast goes to the
    ///     topmost presented screen over it, or to `source` itself when
    ///     nothing covers it (see `host(for:)`).
    ///   - floor: what the capsule stands on instead of the safe area — the
    ///     top of a composer resting there (#729). Only used when the toast
    ///     lands on `source` itself: on a sheet above it, the floor belongs to
    ///     a screen that is no longer in view.
    ///   - position: one of six places (#954); the bottom centre by default.
    ///   - action: one trailing action ("Retry", "View"); the toast leaves
    ///     once it has run.
    @discardableResult
    public static func success(
        _ message: String,
        symbol: String? = Kind.success.defaultSymbol,
        from source: UIViewController,
        above floor: UIView? = nil,
        at position: ToastPosition = .bottom,
        action: ToastView.Action? = nil,
        id: String? = nil
    ) -> ToastView {
        show(.success, message, symbol: symbol, from: source, above: floor, at: position, action: action, id: id)
    }

    /// The action did not happen: a failure-style toast and an error haptic.
    /// It stays until closed, acted on or replaced (#954).
    @discardableResult
    public static func failure(
        _ message: String,
        symbol: String? = Kind.failure.defaultSymbol,
        from source: UIViewController,
        above floor: UIView? = nil,
        at position: ToastPosition = .bottom,
        action: ToastView.Action? = nil,
        id: String? = nil
    ) -> ToastView {
        show(.failure, message, symbol: symbol, from: source, above: floor, at: position, action: action, id: id)
    }

    /// It happened, with a catch: a warning-style toast and a warning haptic.
    @discardableResult
    public static func warning(
        _ message: String,
        symbol: String? = Kind.warning.defaultSymbol,
        from source: UIViewController,
        above floor: UIView? = nil,
        at position: ToastPosition = .bottom,
        action: ToastView.Action? = nil,
        id: String? = nil
    ) -> ToastView {
        show(.warning, message, symbol: symbol, from: source, above: floor, at: position, action: action, id: id)
    }

    /// An action the viewer can take back (#954): a confirmation toast with
    /// Undo and a ring counting down `ToastView.undoDuration`, and a success
    /// haptic. Exactly one of `commit` and `undo` runs, once — see
    /// `ToastView.Undoable` for when it commits.
    ///
    /// - Parameter playsHaptic: false where the action already played its
    ///   own (a stake's impact, on every tap of a burst).
    @discardableResult
    public static func undoable(
        _ message: String,
        symbol: String? = Kind.success.defaultSymbol,
        from source: UIViewController,
        above floor: UIView? = nil,
        at position: ToastPosition = .bottom,
        id: String? = nil,
        playsHaptic: Bool = true,
        commit: @escaping @MainActor () -> Void,
        undo: @escaping @MainActor () -> Void
    ) -> ToastView {
        show(
            .success, message, symbol: symbol, from: source, above: floor, at: position,
            action: nil, undoable: ToastView.Undoable(commit: commit, undo: undo), id: id,
            playsHaptic: playsHaptic
        )
    }

    /// A condition the viewer should know while it lasts ("Offline", #955):
    /// no haptic, no timer and no close button — it stays until a toast with
    /// the same `id` replaces it in place ("Back online"). It takes priority
    /// over the plain confirmations at its position.
    @discardableResult
    public static func condition(
        _ message: String,
        symbol: String? = Kind.info.defaultSymbol,
        id: String,
        from source: UIViewController,
        at position: ToastPosition = .top
    ) -> ToastView {
        show(.info, message, symbol: symbol, from: source, above: nil, at: position, action: nil, id: id, isCondition: true)
    }

    /// Something is under way ("Posting…"): a spinner, no haptic, and no
    /// timer — it stays until a toast with the same `id` (success, failure…)
    /// replaces it in place (#954).
    @discardableResult
    public static func loading(
        _ message: String,
        id: String,
        from source: UIViewController,
        above floor: UIView? = nil,
        at position: ToastPosition = .bottom
    ) -> ToastView {
        show(.loading, message, symbol: nil, from: source, above: floor, at: position, action: nil, id: id)
    }

    /// A neutral notice: a confirmation-style toast, no haptic.
    @discardableResult
    public static func info(
        _ message: String,
        symbol: String? = Kind.info.defaultSymbol,
        from source: UIViewController,
        above floor: UIView? = nil,
        at position: ToastPosition = .bottom,
        action: ToastView.Action? = nil,
        id: String? = nil
    ) -> ToastView {
        show(.info, message, symbol: symbol, from: source, above: floor, at: position, action: action, id: id)
    }

    /// A state that shows on the control itself — a bookmark filling — was
    /// toggled: a light tap and NO toast (#803). The glyph already says what
    /// happened; a toast would repeat it over the content, but the hand still
    /// deserves to feel that the press landed.
    public static func toggled() {
        playToggleHaptic()
    }

    /// Plays the toggle's light impact. Swappable for tests, like
    /// `playHaptic`.
    static var playToggleHaptic: () -> Void = {
        toggleImpact.impactOccurred()
    }

    private static let toggleImpact = HapticImpact(style: .light)

    /// Plays a kind's haptic. Swappable so a test can see which one played
    /// without a device; always restored by the test that swaps it.
    static var playHaptic: (UINotificationFeedbackGenerator.FeedbackType) -> Void = { type in
        notifier.notificationOccurred(type)
    }

    /// One generator for the app's lifetime: built once, so it is not cold
    /// every time (see `HapticNotification`).
    private static let notifier = HapticNotification()

    private static func show(
        _ kind: Kind,
        _ message: String,
        symbol: String?,
        from source: UIViewController,
        above floor: UIView?,
        at position: ToastPosition,
        action: ToastView.Action?,
        undoable: ToastView.Undoable? = nil,
        id: String? = nil,
        isCondition: Bool = false,
        playsHaptic: Bool = true
    ) -> ToastView {
        let host = host(for: source)
        // EXPERIMENT (#1058, `-toast-in-navbar`): in the top bar, as its
        // trailing items, when the screen shows one.
        if NavigationBarToasts.isEnabled, let toast = NavigationBarToasts.present(
            ToastView.Content(
                message: message, symbol: symbol, style: kind.style, action: action,
                undoable: undoable, id: id, isCondition: isCondition
            ),
            from: host
        ) {
            if playsHaptic, let haptic = kind.haptic { playHaptic(haptic) }
            return toast
        }
        let floor = host === source && floor?.window != nil ? floor : nil
        let toast: ToastView
        if let window = host.viewIfLoaded?.window, let overlay = ToastOverlay.overlay(for: window) {
            // The scene's overlay (#954): the toast outlives the screen.
            toast = overlay.present(
                message, symbol: symbol, style: kind.style, action: action, undoable: undoable,
                id: id, isCondition: isCondition, position: position,
                from: host, above: floor,
                keyboardTopY: keyboardTopY(of: host, in: window),
                interfaceStyle: pinnedStyle(of: host)
            )
        } else {
            // No scene to draw over (a package test host): in the screen.
            toast = ToastView.present(
                message, symbol: symbol, style: kind.style, action: action, undoable: undoable,
                id: id, isCondition: isCondition, position: position, in: host.view,
                edge: position.isTop ? nil : floor?.topAnchor
            )
        }
        if playsHaptic, let haptic = kind.haptic { playHaptic(haptic) }
        return toast
    }

    /// The style `host` pins — its own override or its nearest parent's —
    /// or unspecified: the window's. Read from the overrides rather than the
    /// trait collection, which a just-changed override has not reached yet.
    static func pinnedStyle(of host: UIViewController) -> UIUserInterfaceStyle {
        var controller: UIViewController? = host
        while let current = controller {
            if current.overrideUserInterfaceStyle != .unspecified { return current.overrideUserInterfaceStyle }
            controller = current.parent
        }
        return .unspecified
    }

    /// Where a bottom toast from `host` stands, in `window`'s coordinates:
    /// the top of `floor` (a composer), or else the host's safe area bottom —
    /// which clears its tab bar, toolbar and tab accessory. The keyboard is
    /// the overlay's to follow (`keyboardTopY(of:in:)`).
    static func floorY(of host: UIViewController?, above floor: UIView?, in window: UIWindow) -> CGFloat {
        if let floor {
            return floor.convert(floor.bounds, to: window).minY
        }
        guard let view = host?.viewIfLoaded else { return window.bounds.maxY - window.safeAreaInsets.bottom }
        return view.convert(view.safeAreaLayoutGuide.layoutFrame, to: window).maxY
    }

    /// The keyboard's top in `window`'s coordinates while it is up over
    /// `host`, else nil — the overlay's starting point; it follows the
    /// keyboard's moves from there.
    static func keyboardTopY(of host: UIViewController, in window: UIWindow) -> CGFloat? {
        let view = host.view!
        let safe = view.convert(view.safeAreaLayoutGuide.layoutFrame, to: window).maxY
        let keyboard = view.convert(view.keyboardLayoutGuide.layoutFrame, to: window).minY
        return keyboard < safe - 1 ? keyboard : nil
    }

    /// Where a toast from `source` is drawn.
    ///
    /// The topmost presented screen in `source`'s window — so a toast fired
    /// from a screen a sheet now covers shows on the sheet — unless `source`
    /// IS that screen or sits inside it, in which case `source` itself. That
    /// second rule matters: the window's root is the tab shell, whose view's
    /// safe area does not clear the tab bar, while the screen on top of a tab
    /// does. A screen not in a window (dismissed, popped) keeps its own view:
    /// there is nothing better to guess.
    ///
    /// The walk stops under a screen already on its way out, and under a
    /// SYSTEM SURFACE (`isSystemSurface`): an alert, a share sheet, a photo
    /// picker, a Safari view, a popover. Their views are not ours to draw in —
    /// a toast added inside a share sheet's remote UI is clipped, misplaced,
    /// or simply lost.
    ///
    /// A tab shell is never the host itself, for the same safe-area reason:
    /// a toast sourced from it (a sheet's presenter, after the sheet has gone
    /// — "Posted", #803) goes to its selected tab, which clears the tab bar.
    public static func host(for source: UIViewController) -> UIViewController {
        guard let root = source.viewIfLoaded?.window?.rootViewController else { return intoSelectedTab(source) }
        var top = root
        while let presented = top.presentedViewController,
              !presented.isBeingDismissed,
              !isSystemSurface(presented) {
            top = presented
        }
        var ancestor: UIViewController? = source
        while let current = ancestor {
            if current === top { return intoSelectedTab(source) }
            ancestor = current.parent
        }
        return intoSelectedTab(top)
    }

    /// Whether a presented controller is one the system draws — never a toast
    /// host.
    ///
    /// Named where UIKit lets us (alerts, share sheets) and for any popover;
    /// otherwise by where its class lives: a controller defined in a system
    /// framework (PhotosUI's picker, SafariServices, document pickers…) is the
    /// system's, except the generic containers the app presents its own
    /// screens in. Asked by class rather than by import, so DesignSystem
    /// needs neither PhotosUI nor SafariServices.
    static func isSystemSurface(_ controller: UIViewController) -> Bool {
        if controller is UIAlertController || controller is UIActivityViewController { return true }
        if controller.modalPresentationStyle == .popover { return true }
        let controllerClass: AnyClass = type(of: controller)
        let ordinary: [AnyClass] = [
            UIViewController.self, UINavigationController.self, UITabBarController.self,
            UISplitViewController.self, UIPageViewController.self, UISearchController.self,
        ]
        if ordinary.contains(where: { $0 == controllerClass }) { return false }
        return Bundle(for: controllerClass).bundlePath.contains("/System/Library/")
    }

    private static func intoSelectedTab(_ host: UIViewController) -> UIViewController {
        guard let tabs = host as? UITabBarController, let selected = tabs.selectedViewController,
              selected.isViewLoaded else { return host }
        return selected
    }
}
