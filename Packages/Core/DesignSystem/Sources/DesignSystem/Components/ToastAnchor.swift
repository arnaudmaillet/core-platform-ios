import UIKit

/// A screen whose own top chrome sits UNDER its navigation bar, or stands in
/// for one (#2143): a toast hangs under that chrome instead of the bar.
///
/// Adopted by:
/// - the camera (`CaptureViewController`): its recording time pill, under
///   the bar, while it shows.
///
/// Every other screen's top is a native bar (the snap feed's, For You's
/// pushed header, the profile's immersive header all are), which the anchor
/// reads on its own.
@MainActor
public protocol ToastAnchoring: AnyObject {
    /// The view whose bottom edge toasts hang under while it shows; nil, or
    /// a view not on screen: the screen's navigation bar, else the status
    /// bar.
    var toastAnchorView: UIView? { get }
}

/// Where a toast hangs (#2143): ONE place on every screen, just under the top
/// bar of the screen in view, read again on every frame a toast is up.
///
/// | Screen in view | The anchor |
/// |---|---|
/// | a visible navigation bar (small or large title, a search field or a pinned header in it) | the bar's bottom edge |
/// | a screen with its own top chrome (`ToastAnchoring`) | the bottom of that chrome |
/// | no bar and no chrome | the top safe area: under the status bar and the Dynamic Island |
/// | a sheet leaving the top of the screen in view (a medium detent) | the screen behind it, as if the sheet were not there |
/// | a sheet covering the top (a large detent) | the sheet's own bar, or its grabber's area if it has none |
///
/// The screen in view is the app window's, read from its root: the topmost
/// presentation that covers the top, then a stack's top, a tab shell's
/// selected tab, a custom container's full-screen child — so a push, a pop,
/// a tab switch or a sheet move the anchor, never the toast's owner.
@MainActor
enum ToastAnchor {
    /// Below a sheet's top edge, the room its grabber takes.
    static let grabberRoom: CGFloat = 16
    /// A sheet whose top is this far below the anchor of the screen behind
    /// leaves that screen's top in view: room for a toast and its gap.
    static let roomAboveSheet: CGFloat = 64

    /// The anchor's foot in `window`'s coordinates: what toasts hang under.
    static func anchorY(in window: UIWindow) -> CGFloat {
        let (screen, sheetTop) = screenInView(in: window)
        return anchorY(of: screen, in: window, sheetTop: sheetTop)
    }

    /// The screen a toast hangs over, and — when it sits in a sheet that does
    /// not reach the top of the window — that sheet's top edge.
    static func screenInView(in window: UIWindow) -> (screen: UIViewController?, sheetTop: CGFloat?) {
        guard let root = window.rootViewController else { return (nil, nil) }
        // The root, then each presentation over it, with its top edge (nil:
        // not in this window, so covering nothing).
        var chain: [(controller: UIViewController, top: CGFloat?)] = [(root, nil)]
        var top = root
        while let presented = top.presentedViewController,
              !presented.isBeingDismissed,
              !Feedback.isSystemSurface(presented),
              !Feedback.isToastMessageSheet(presented) {
            top = presented
            let view = presented.viewIfLoaded
            chain.append((presented, view?.window === window ? view.map { $0.convert($0.bounds, to: window).minY } : nil))
        }
        var sheetTop: CGFloat?
        let index = holder(presentationTops: chain.map(\.top)) { index in
            anchorY(of: visibleScreen(in: chain[index].controller), in: window, sheetTop: sheetTop)
        } onHolder: { index in
            sheetTop = chain[index].top.flatMap { $0 > window.bounds.minY + 1 ? $0 : nil }
        }
        return (visibleScreen(in: chain[index].controller), sheetTop)
    }

    /// Which of a chain of screens — the root, then each presentation over
    /// it, with its top edge — holds the toast: the last one whose top comes
    /// above the anchor of the one holding it so far, less `roomAboveSheet`.
    /// A sheet that leaves the top of the screen behind in view (a medium
    /// detent) holds nothing: the toast stays behind it, covering neither the
    /// sheet nor its content — though one higher up, over it, may still
    /// cover the top.
    ///
    /// - Parameters:
    ///   - presentationTops: per screen, its top edge; nil for the root and
    ///     for a presentation not on screen.
    ///   - anchorOf: the anchor of the screen at an index.
    ///   - onHolder: told each time a screen takes the toast.
    static func holder(
        presentationTops: [CGFloat?],
        anchorOf: (Int) -> CGFloat,
        onHolder: (Int) -> Void = { _ in }
    ) -> Int {
        var holder = 0
        for (index, top) in presentationTops.enumerated().dropFirst() {
            guard let top, top < anchorOf(holder) + roomAboveSheet else { continue }
            holder = index
            onHolder(index)
        }
        return holder
    }

    /// The anchor of `screen` (see the type doc), never above the status
    /// band.
    static func anchorY(of screen: UIViewController?, in window: UIWindow, sheetTop: CGFloat?) -> CGFloat {
        let safeTop = window.bounds.minY + window.safeAreaInsets.top
        guard let screen else { return safeTop }
        // Its own chrome first: the screen, or a container around it inside
        // its stack.
        var controller: UIViewController? = screen
        while let current = controller, !(current is UINavigationController), !(current is UITabBarController) {
            if let anchoring = current as? ToastAnchoring, let view = anchoring.toastAnchorView, isShowing(view, in: window) {
                return max(safeTop, view.convert(view.bounds, to: window).maxY)
            }
            controller = current.parent
        }
        if let stack = screen.navigationController, !stack.isNavigationBarHidden,
           isShowing(stack.navigationBar, in: window) {
            let bar = stack.navigationBar
            return max(safeTop, bar.convert(bar.bounds, to: window).maxY)
        }
        if let sheetTop { return max(safeTop, sheetTop + grabberRoom) }
        return safeTop
    }

    /// Whether `view` shows in `window` now: in it, and neither it nor any
    /// view around it hidden or transparent.
    static func isShowing(_ view: UIView, in window: UIWindow) -> Bool {
        guard view.window === window, view.bounds.height > 0 else { return false }
        var current: UIView? = view
        while let shown = current {
            if shown.isHidden || shown.alpha < 0.01 { return false }
            current = shown.superview
        }
        return true
    }

    /// The screen a container shows: a stack's top, a tab shell's selected
    /// tab, all the way down — the one whose navigation bar is the anchor.
    static func visibleScreen(in controller: UIViewController) -> UIViewController {
        var screen = controller
        while true {
            if let stack = screen as? UINavigationController, let top = stack.topViewController {
                screen = top
            } else if let tabs = screen as? UITabBarController, let selected = tabs.selectedViewController {
                screen = selected
            } else if let child = largestVisibleChild(of: screen) {
                // Any other container — the notifications drawer, beside the
                // tab shell it pushes aside: into the child that takes most
                // of it.
                screen = child
            } else {
                return screen
            }
        }
    }

    /// The child of a custom container covering the most of it, if that is
    /// at least half of it — the open notifications drawer takes ~85 % and
    /// the shell it pushed aside the rest (#2143: at 90 % the drawer was
    /// missed, and the toast fell into its bar). Going into a leaf screen's
    /// own big child (a pager's page) is harmless: its bar and its chrome
    /// are found walking back up.
    private static func largestVisibleChild(of container: UIViewController) -> UIViewController? {
        guard let window = container.viewIfLoaded?.window else { return nil }
        let containerArea = area(of: container.view, in: window)
        guard containerArea > 0 else { return nil }
        let best = container.children
            .filter { $0.viewIfLoaded?.window === window && !$0.view.isHidden }
            .map { ($0, area(of: $0.view, in: window)) }
            .max { $0.1 < $1.1 }
        guard let best, best.1 >= containerArea * 0.5 else { return nil }
        return best.0
    }

    private static func area(of view: UIView, in window: UIWindow) -> CGFloat {
        let visible = view.convert(view.bounds, to: window).intersection(window.bounds)
        return visible.isNull ? 0 : visible.width * visible.height
    }
}
