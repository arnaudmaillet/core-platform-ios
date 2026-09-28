import UIKit

#if DEBUG

/// `-dock-trace` — the dock's VISIBLE opacity, sampled every frame and printed
/// on change, so "does the tab bar fade in during a return, or appear at the
/// landing?" is a timeline rather than an impression.
///
/// What is printed is what the viewer sees, not what the model says: the
/// product of every PRESENTATION-layer opacity from the view up to its window,
/// and zero when anything on that path is hidden or the view is not in a
/// window at all. A bar at model alpha 1 whose alpha animation is still
/// running reads as the in-flight value; a bar whose state reads visible while
/// an ancestor is hidden reads 0.
///
/// Both halves of the bottom chrome are traced — the system tab bar and the
/// bottom accessory's content (For You's Discover/Following selector, the place
/// page's Discover/Activity pill) — because the product rule is that they come
/// back TOGETHER, at the landing.
///
///     [dock] +7901ms moving top=ForYouViewController bar=0.00(m0.00) y=791 hidden=N acc=none
///     [dock] +9293ms rest top=ForYouViewController bar=1.00(m1.00) y=791 hidden=N acc=1.00
///
/// `bar` is what is drawn, `m` the model alpha (they differ while an alpha
/// animation runs, listed as `anim=`), `rest` the first frame after the
/// transition completed — the landing.
@MainActor
final class DockTrace {
    private static var shared: DockTrace?

    static func installIfRequested(tabBarController: UITabBarController) {
        guard ProcessInfo.processInfo.arguments.contains("-dock-trace"), shared == nil else { return }
        shared = DockTrace(tabBarController: tabBarController)
    }

    private let tabBarController: UITabBarController
    private let start = CACurrentMediaTime()
    private var link: CADisplayLink?
    private var last = ""

    private init(tabBarController: UITabBarController) {
        self.tabBarController = tabBarController
        let link = CADisplayLink(target: Proxy(self), selector: #selector(Proxy.tick))
        link.add(to: .main, forMode: .common)
        self.link = link
        print("[dock] START")
    }

    /// A display link retains its target; the proxy keeps that from pinning
    /// the trace (and through it the tab bar controller) forever.
    private final class Proxy: NSObject {
        weak var owner: DockTrace?
        init(_ owner: DockTrace) { self.owner = owner }
        @objc func tick() { MainActor.assumeIsolated { owner?.sample() } }
    }

    private func sample() {
        let bar = tabBarController.tabBar
        let accessory = tabBarController.bottomAccessory?.contentView
        // Where the bar is DRAWN: presentation layer to presentation layer, so a
        // slide in flight reads as its in-flight position.
        let barY = bar.window.map { window -> CGFloat in
            let layer = bar.layer.presentation() ?? bar.layer
            return layer.convert(layer.bounds, to: window.layer.presentation() ?? window.layer).minY
        } ?? -1
        let nav = tabBarController.selectedViewController as? UINavigationController
        let top = nav?.topViewController.map { String(describing: type(of: $0)) } ?? "?"
        // `moving` while the stack has a transition in flight, `rest` once it
        // has landed — the landing is the instant the dock is owed.
        let phase = nav?.transitionCoordinator != nil ? "moving" : "rest"
        let line = String(
            format: "%@ top=%@ bar=%.2f(m%.2f%@) y=%.0f hidden=%@ acc=%@",
            phase, top, Self.visibleOpacity(of: bar), bar.alpha,
            (bar.layer.animationKeys() ?? []).isEmpty ? "" : " anim=" + (bar.layer.animationKeys() ?? []).joined(separator: ","),
            barY,
            tabBarController.isTabBarHidden ? "Y" : "N",
            accessory.map {
                // Whether the band rides the bar's own opacity (a descendant
                // of it) or has to be driven separately.
                String(format: "%.2f%@", Self.visibleOpacity(of: $0), $0.isDescendant(of: bar) ? "(in bar)" : "")
            } ?? "none"
        )
        guard line != last else { return }
        last = line
        print(String(format: "[dock] +%.0fms ", (CACurrentMediaTime() - start) * 1000) + line
              + (tabBarController.isTabBarHidden ? "" : Self.whyInvisible(bar))
              + (accessory.map(Self.whatIsFading) ?? ""))
    }

    /// For a bar whose STATE reads shown: the first thing on its path to the
    /// window that stops it drawing — `hidden=false viewHidden=true` is a
    /// defect this repo has met before, and it reads as "no dock" on video.
    private static func whyInvisible(_ view: UIView) -> String {
        guard view.window != nil else { return " [no window]" }
        var node: UIView? = view
        while let current = node {
            if current.isHidden { return " [hidden: \(type(of: current))]" }
            if (current.layer.presentation()?.opacity ?? current.layer.opacity) < 0.01 {
                return " [alpha0: \(type(of: current))]"
            }
            node = current.superview
        }
        return ""
    }

    /// The first view on the accessory's path to the window that is drawn
    /// part-transparent, with its model alpha and running animations — which
    /// tells a fade UIKit runs from one this app wrote.
    private static func whatIsFading(_ view: UIView) -> String {
        var node: UIView? = view
        while let current = node {
            let shown = CGFloat(current.layer.presentation()?.opacity ?? current.layer.opacity)
            if shown < 0.99 {
                let keys = (current.layer.animationKeys() ?? []).joined(separator: ",")
                return String(format: " [acc fading: %@ m%.2f %@]", "\(type(of: current))", current.alpha, keys)
            }
            node = current.superview
        }
        return ""
    }

    /// What reaches the screen: the product of the presentation opacities up
    /// to the window, zero for anything hidden or windowless.
    private static func visibleOpacity(of view: UIView) -> CGFloat {
        guard view.window != nil else { return 0 }
        var opacity: CGFloat = 1
        var node: UIView? = view
        while let current = node {
            if current.layer.presentation()?.isHidden ?? current.isHidden { return 0 }
            opacity *= CGFloat(current.layer.presentation()?.opacity ?? current.layer.opacity)
            node = current.superview
        }
        return opacity
    }
}

#endif
