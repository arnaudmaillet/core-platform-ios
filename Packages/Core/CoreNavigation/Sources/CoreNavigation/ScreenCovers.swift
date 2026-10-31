import DesignSystem
import ObjectiveC
import UIKit

/// WHAT COVERS THE SCREENS OF A WINDOW (#1970, the owner 2026-10-31: "the
/// most robust and decoupled"): every presentation, whoever made it — the
/// app, the system, an SDK — plus covers that are not presentations
/// (`begin(covers:)`). A clip host's `ViewportShare` reads 0 while a cover
/// above its own level hides it, and its other sources take over again when
/// the cover ends.
///
/// ```
///   AppWindow.didAddSubview / willRemoveSubview   (a presentation comes or goes)
///     → the next turn: the root's presentedViewController chain, read again
///       → each level: declared (ScreenCovering), or the default table
///         → every live share in the window: covered by a level above its own?
/// ```
///
/// - **The level** of a screen is its place in the window's presentation
///   chain: 0 for the root's screens, 1 for what the root presents, and so
///   on. Only a cover above a host's level hides it: the sound sheet does not
///   pause the gallery inside it.
/// - **It fails open.** If UIKit ever stopped installing a presentation's
///   container in the window, the window would hear nothing and clips would
///   play on as they did before — never one stuck paused. A host out of the
///   window is never held covered.
/// - **Public API only:** the presentation chain, `modalPresentationStyle`,
///   `sheetPresentationController?.selectedDetentIdentifier`, the presented
///   view's frame. No display link: it reads on a change, never polls (#580).
@MainActor
public final class ScreenCovers {
    private weak var window: UIWindow?
    private var tokens: [WeakToken] = []
    private var isRefreshScheduled = false
    /// The levels whose cover hides what is under them, as last read.
    private(set) var coveringLevels: [Int] = []

    private init(window: UIWindow) {
        self.window = window
    }

    /// The window's registry, made on first use.
    public static func of(_ window: UIWindow) -> ScreenCovers {
        if let existing = objc_getAssociatedObject(window, &Key.registry) as? ScreenCovers { return existing }
        let registry = ScreenCovers(window: window)
        objc_setAssociatedObject(window, &Key.registry, registry, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return registry
    }

    /// Listens to every `AppWindow`'s presentations, once. Called by the
    /// first `ViewportShare`: a window with no clip host has nothing to tell.
    static func startListening() {
        guard listeners.isEmpty else { return }
        let center = NotificationCenter.default
        listeners.append(center.addObserver(forName: AppWindow.subviewsDidChange, object: nil, queue: .main) { note in
            guard let window = note.object as? UIWindow else { return }
            MainActor.assumeIsolated { ScreenCovers.of(window).scheduleRefresh() }
        })
        // A declared cover's state changed (`ScreenCovering.coverChanged()`):
        // its window reads it again now.
        listeners.append(center.addObserver(forName: ScreenCoveringNotification.didChange, object: nil, queue: .main) { note in
            // Posted on the main actor (`coverChanged()` is isolated to it),
            // and delivered there.
            nonisolated(unsafe) let object = note.object
            MainActor.assumeIsolated {
                guard let screen = object as? UIViewController,
                      let window = screen.viewIfLoaded?.window ?? screen.presentingViewController?.viewIfLoaded?.window
                else { return }
                ScreenCovers.of(window).refresh()
            }
        })
    }

    private static var listeners: [NSObjectProtocol] = []

    // MARK: - Covers that are not presentations

    /// A cover that is not a presentation — a popup view, a window of its
    /// own, a full-screen overlay: it hides every screen of the window's
    /// present levels while `covers` holds, until `end()` or until the token
    /// goes away.
    public func begin(covers: Bool) -> Token {
        let token = Token(registry: self, level: currentDepth + 1, covers: covers)
        tokens.append(WeakToken(token))
        refresh()
        return token
    }

    /// A cover that is not a presentation; it ends when released.
    @MainActor
    public final class Token {
        // Read by `deinit`, which runs off the actor.
        fileprivate nonisolated(unsafe) weak var registry: ScreenCovers?
        fileprivate let level: Int
        /// Whether it hides the screens under it now.
        public var covers: Bool {
            didSet { if covers != oldValue { registry?.refresh() } }
        }
        fileprivate nonisolated(unsafe) var isEnded = false

        fileprivate init(registry: ScreenCovers, level: Int, covers: Bool) {
            self.registry = registry
            self.level = level
            self.covers = covers
        }

        /// Ends the cover now.
        public func end() {
            guard !isEnded else { return }
            isEnded = true
            registry?.refresh()
        }

        deinit {
            guard !isEnded, let registry else { return }
            // Told on the next turn: the token is mid-release here.
            Task { @MainActor in registry.refresh() }
        }
    }

    private struct WeakToken {
        weak var token: Token?
        init(_ token: Token) { self.token = token }
    }

    // MARK: - Reading

    /// The window's presentation chain: its root, then what each presents.
    var chain: [UIViewController] {
        guard var top = window?.rootViewController else { return [] }
        var chain = [top]
        while let presented = top.presentedViewController {
            chain.append(presented)
            top = presented
        }
        return chain
    }

    private var currentDepth: Int { max(0, chain.count - 1) }

    /// Reads again on the next turn, once: a container joins the window as a
    /// presentation begins, and leaves it as a dismissal ends — the chain is
    /// settled a moment later.
    func scheduleRefresh() {
        guard !isRefreshScheduled else { return }
        isRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            isRefreshScheduled = false
            refresh()
        }
    }

    /// Reads the covers again and tells every live share in the window.
    func refresh() {
        guard let window else { return }
        let chain = chain
        var levels: [Int] = []
        for (level, screen) in chain.enumerated() where level > 0 {
            if Self.covers(screen, in: window.bounds) { levels.append(level) }
        }
        tokens.removeAll { $0.token == nil || $0.token?.isEnded == true }
        for token in tokens.compactMap(\.token) where token.covers {
            levels.append(token.level)
        }
        coveringLevels = levels
        for share in ViewportShare.live {
            guard let host = share.hostView else { continue }
            guard let hostWindow = host.window else {
                // Out of every window: never held covered (it fails open).
                share.setCovered(false)
                continue
            }
            // Another window's host is that window's to tell.
            guard hostWindow === window else { continue }
            let level = Self.level(of: host, in: chain)
            share.setCovered(levels.contains { $0 > level })
        }
    }

    /// `host`'s level: the deepest screen of `chain` holding it.
    static func level(of host: UIView, in chain: [UIViewController]) -> Int {
        var found = 0
        for (level, screen) in chain.enumerated() {
            if let view = screen.viewIfLoaded, host.isDescendant(of: view) { found = level }
        }
        return found
    }

    // MARK: - The default table

    /// Whether `presented` hides the screens under it, in a window of
    /// `bounds` (#1970):
    ///
    /// | Presentation | Covers |
    /// |---|---|
    /// | declared (`ScreenCovering`, itself or its stack's root) | what it says |
    /// | `.fullScreen`, `.overFullScreen` | yes |
    /// | a sheet whose selected detent is `.large()` | yes |
    /// | a sheet at any smaller detent (medium, custom, fitted) | no |
    /// | an alert, an action sheet, a popover | no |
    /// | anything else (a custom transition) | when its view fills the window |
    ///
    /// ⚠️ A SHEET CHANGING HEIGHT WHILE UP IS NOT SEEN: nothing joins or
    /// leaves the window. Such an app sheet declares itself
    /// (`ScreenCoveringGuardTests`); a system one (the share sheet) is read
    /// when it opens and when it closes.
    public static func covers(_ presented: UIViewController, in bounds: CGRect) -> Bool {
        if let declared = declaration(of: presented) { return declared.coversScreen }
        if presented is UIAlertController { return false }
        switch presented.modalPresentationStyle {
        case .fullScreen, .overFullScreen:
            return true
        case .popover:
            return false
        case .pageSheet, .formSheet, .automatic:
            if let sheet = presented.sheetPresentationController {
                return coversAsSheet(selected: sheet.selectedDetentIdentifier, detents: sheet.detents.map(\.identifier))
            }
        default:
            break
        }
        return fills(presented, bounds)
    }

    /// A sheet covers at `.large()` — see `ScreenCoveringSheet` for none
    /// selected (UIKit shows the smallest). Pure, for tests.
    static func coversAsSheet(
        selected: UISheetPresentationController.Detent.Identifier?,
        detents: [UISheetPresentationController.Detent.Identifier]
    ) -> Bool {
        ScreenCoveringSheet.coversAtLarge(selected: selected, detents: detents)
    }

    /// The declaring screen: `presented` itself, or the root of its stack.
    static func declaration(of presented: UIViewController) -> (any ScreenCovering)? {
        if let declared = presented as? any ScreenCovering { return declared }
        if let stack = presented as? UINavigationController,
           let root = stack.viewControllers.first as? any ScreenCovering { return root }
        return nil
    }

    /// Whether `presented`'s view takes nine tenths of the window or more —
    /// where it will stand, not where an animation has it now.
    private static func fills(_ presented: UIViewController, _ bounds: CGRect) -> Bool {
        guard let controller = presented.presentationController, controller.containerView != nil,
              bounds.width > 0, bounds.height > 0 else { return false }
        let frame = controller.frameOfPresentedViewInContainerView.intersection(bounds)
        guard !frame.isNull else { return false }
        return frame.width * frame.height >= 0.9 * bounds.width * bounds.height
    }

    private enum Key {
        nonisolated(unsafe) static var registry: UInt8 = 0
    }
}
