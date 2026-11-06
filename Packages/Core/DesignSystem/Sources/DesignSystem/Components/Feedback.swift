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
///   kind pairs its outcome role (`Haptic.success`, `.warning`, `.error`,
///   #1881), played through `Haptics`, so the Haptics switch (#470) is
///   honoured.
///
/// Wording (the toast's own rule): short, past tense for a result, no
/// trailing period — "Copied", "Report sent", "Couldn't follow @ava".
///
/// ## One place (#2143)
///
/// Every toast is drawn by the scene's `ToastOverlay`, just under the top bar
/// of the screen in view (`ToastAnchor`), and follows it through a push, a
/// pop, a tab switch or a sheet. It never takes a bar item's place, so a
/// control a toast confirms (a bell, a Follow) shows its new look at once —
/// #2116's rule — and the toast says what happened; a refusal rolls it back
/// and says why with `failure`. (Until #2143 a toast took the bar's trailing
/// items, and such a control held its old look under it, #1447.)
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

        /// The outcome role the toast arrives with, if any (#1881).
        public var haptic: Haptic? {
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
    ///   - action: one trailing action ("Retry", "View"); the toast leaves
    ///     once it has run.
    @discardableResult
    public static func success(
        _ message: String,
        symbol: String? = Kind.success.defaultSymbol,
        from source: UIViewController,
        action: ToastView.Action? = nil,
        id: String? = nil
    ) -> ToastView {
        show(.success, message, symbol: symbol, from: source, action: action, id: id)
    }

    /// The action did not happen: a failure-style toast and an error haptic.
    /// It leaves on the same timer as the other toasts (#1448) — or, with
    /// `length: .long`, after `ToastView.longDuration` at least: for the rare
    /// failure that is the only trace of something lost (#1459).
    @discardableResult
    public static func failure(
        _ message: String,
        symbol: String? = Kind.failure.defaultSymbol,
        from source: UIViewController,
        action: ToastView.Action? = nil,
        id: String? = nil,
        length: ToastView.Length = .standard
    ) -> ToastView {
        show(.failure, message, symbol: symbol, from: source, action: action, id: id, length: length)
    }

    /// It happened, with a catch: a warning-style toast and a warning haptic.
    @discardableResult
    public static func warning(
        _ message: String,
        symbol: String? = Kind.warning.defaultSymbol,
        from source: UIViewController,
        action: ToastView.Action? = nil,
        id: String? = nil
    ) -> ToastView {
        show(.warning, message, symbol: symbol, from: source, action: action, id: id)
    }

    /// An action the viewer can take back (#954): a confirmation toast with
    /// Undo and a ring counting down `ToastView.undoDuration`, and a success
    /// haptic. Exactly one of `commit` and `undo` runs, once — see
    /// `ToastView.Undoable` for when it commits.
    ///
    /// - Parameters:
    ///   - playsHaptic: false where the action already played its own (a
    ///     stake's impact, on every tap of a burst).
    @discardableResult
    public static func undoable(
        _ message: String,
        symbol: String? = Kind.success.defaultSymbol,
        from source: UIViewController,
        id: String? = nil,
        playsHaptic: Bool = true,
        commit: @escaping @MainActor () -> Void,
        undo: @escaping @MainActor () -> Void
    ) -> ToastView {
        show(
            .success, message, symbol: symbol, from: source,
            action: nil, undoable: ToastView.Undoable(commit: commit, undo: undo), id: id,
            playsHaptic: playsHaptic
        )
    }

    /// A condition the viewer should know while it lasts ("Offline", #955):
    /// no haptic, no timer and no close button — it stays until a toast with
    /// the same `id` replaces it in place ("Back online"). It holds its own
    /// line: a result toast fired meanwhile hangs just under it.
    @discardableResult
    public static func condition(
        _ message: String,
        symbol: String? = Kind.info.defaultSymbol,
        id: String,
        from source: UIViewController
    ) -> ToastView {
        show(.info, message, symbol: symbol, from: source, action: nil, id: id, isCondition: true)
    }

    /// Something is under way ("Posting…"): a spinner, no haptic, and no
    /// timer — it stays until a toast with the same `id` (success, failure…)
    /// replaces it in place (#954).
    @discardableResult
    public static func loading(
        _ message: String,
        id: String,
        from source: UIViewController
    ) -> ToastView {
        show(.loading, message, symbol: nil, from: source, action: nil, id: id)
    }

    /// A neutral notice: a confirmation-style toast, no haptic.
    @discardableResult
    public static func info(
        _ message: String,
        symbol: String? = Kind.info.defaultSymbol,
        from source: UIViewController,
        action: ToastView.Action? = nil,
        id: String? = nil
    ) -> ToastView {
        show(.info, message, symbol: symbol, from: source, action: action, id: id)
    }

    /// A state that shows on the control itself — a bookmark filling — was
    /// toggled: NO toast (#803), and `toggleOn` when it turned ON only —
    /// turning off is silent (#1881). The glyph already says what happened;
    /// a toast would repeat it over the content, but the hand still deserves
    /// to feel that the press landed. The caller says which: this does not
    /// guess.
    public static func toggled(on isOn: Bool) {
        guard isOn else { return }
        Haptics.play(.toggleOn)
    }

    private static func show(
        _ kind: Kind,
        _ message: String,
        symbol: String?,
        from source: UIViewController,
        action: ToastView.Action?,
        undoable: ToastView.Undoable? = nil,
        id: String? = nil,
        isCondition: Bool = false,
        playsHaptic: Bool = true,
        length: ToastView.Length = .standard
    ) -> ToastView {
        let host = host(for: source)
        let toast: ToastView
        if let window = host.viewIfLoaded?.window, let overlay = ToastOverlay.overlay(for: window) {
            // The scene's overlay (#954), under the top bar of the screen in
            // view (#2143): the toast outlives the screen.
            toast = overlay.present(
                message, symbol: symbol, style: kind.style, action: action, undoable: undoable,
                id: id, isCondition: isCondition, length: length, interfaceStyle: pinnedStyle(of: host)
            )
        } else {
            // No scene to draw over (a package test host): in the screen.
            toast = ToastView.present(
                message, symbol: symbol, style: kind.style, action: action, undoable: undoable,
                id: id, isCondition: isCondition, length: length, in: host.view
            )
        }
        if playsHaptic, let haptic = kind.haptic { Haptics.play(haptic) }
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
    /// It stops under a toast's own full-message sheet too
    /// (`isToastMessageSheet`, #1449).
    ///
    /// A tab shell is never the host itself, for the same safe-area reason:
    /// a toast sourced from it (a sheet's presenter, after the sheet has gone
    /// — "Posted", #803) goes to its selected tab, which clears the tab bar.
    public static func host(for source: UIViewController) -> UIViewController {
        guard let root = source.viewIfLoaded?.window?.rootViewController else { return intoSelectedTab(source) }
        var top = root
        while let presented = top.presentedViewController,
              !presented.isBeingDismissed,
              !isSystemSurface(presented),
              !isToastMessageSheet(presented) {
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

    /// A toast's own full-message sheet (#1449): never a toast's host. A toast
    /// fired while it is up goes to the screen under it.
    static func isToastMessageSheet(_ controller: UIViewController) -> Bool {
        let root = (controller as? UINavigationController)?.viewControllers.first ?? controller
        return root is ToastMessageSheet
    }

    private static func intoSelectedTab(_ host: UIViewController) -> UIViewController {
        guard let tabs = host as? UITabBarController, let selected = tabs.selectedViewController,
              selected.isViewLoaded else { return host }
        return selected
    }
}
