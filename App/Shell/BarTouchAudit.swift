#if DEBUG
import UIKit

/// `-bar-touch-audit` (#562): every 3 s, probes points across each visible
/// bar's area (tab bar, navigation bars, toolbars) and prints how many a TAP
/// would reach in the screen's content WITHOUT the shield ("raw") and WITH it
/// ("guarded": points the shield does not follow). Pans are not the shield's:
/// `BarTapShieldUITests` checks a pan from the tab bar band still scrolls.
///
///     [bar-touch] tab bar {{0, 791}, {402, 83}} 60 probes: content raw=34 guarded=0 (MKMapView…)
///
/// "raw" > 0 is the leak #562 describes; "guarded" must be 0. Items stay
/// reachable: a probe the bar itself answers is never counted.
@MainActor
enum BarTouchAudit {
    private static var timer: Timer?

    static func startIfRequested(in window: UIWindow) {
        guard ProcessInfo.processInfo.arguments.contains("-bar-touch-audit"), timer == nil else { return }
        let timer = Timer(timeInterval: 3, repeats: true) { [weak window] _ in
            MainActor.assumeIsolated {
                guard let window else { return }
                report(in: window)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        Self.timer = timer
    }

    private struct Probe {
        let name: String
        let bar: UIView
        let content: UIView
        /// The area probed, when it is not the bar's own frame.
        var area: CGRect?
    }

    static func report(in window: UIWindow) {
        for probe in probes(in: window) {
            let frame = probe.area ?? probe.bar.convert(probe.bar.bounds, to: window)
            var raw = 0, guarded = 0, total = 0
            var leaked: Set<String> = []
            for point in samples(in: frame) {
                total += 1
                guard let hit = window.hitTest(point, with: nil) else { continue }
                // A tap starting here reaches content unless the shield follows it.
                let shielded = BarTouchGuard.bar(replacing: hit, at: point, in: window) != nil
                if hit.isDescendant(of: probe.content) {
                    raw += 1
                    leaked.insert(String(describing: type(of: hit)))
                    if !shielded { guarded += 1 }
                }
            }
            print("[bar-touch] \(probe.name) \(frame.integral) \(total) probes: content raw=\(raw) guarded=\(guarded)"
                + (leaked.isEmpty ? "" : " (\(leaked.sorted().prefix(4).joined(separator: ", ")))"))
        }
    }

    /// A grid over the bar, clear of the left edge the guard leaves alone.
    private static func samples(in frame: CGRect) -> [CGPoint] {
        let left = max(frame.minX, BarTouchGuard.edgeInset) + 6
        var points: [CGPoint] = []
        for y in [frame.minY + 6, frame.midY, frame.maxY - 6] where frame.height > 12 {
            var x = left
            while x < frame.maxX - 6 {
                points.append(CGPoint(x: x, y: y))
                x += 20
            }
        }
        return points
    }

    /// The bars on screen, each with the content it floats over.
    private static func probes(in window: UIWindow) -> [Probe] {
        var probes: [Probe] = []
        func visit(_ controller: UIViewController) {
            if let tabs = controller as? UITabBarController, let content = tabs.selectedViewController?.viewIfLoaded,
               tabs.tabBar.window === window, !tabs.tabBar.isHidden {
                probes.append(Probe(name: "tab bar", bar: tabs.tabBar, content: content))
                if let accessory = tabs.bottomAccessory?.contentView, accessory.window === window, !tabs.isTabBarHidden {
                    probes.append(Probe(name: "tab accessory", bar: accessory, content: content))
                }
            }
            if let navigation = controller as? UINavigationController,
               let content = navigation.topViewController?.viewIfLoaded, content.window === window {
                if !navigation.isNavigationBarHidden {
                    probes.append(Probe(name: "nav bar \(type(of: navigation.topViewController!))",
                                        bar: navigation.navigationBar, content: content))
                }
                if let band = BarTouchGuard.toolbarBand(of: navigation, content: content, in: window) {
                    probes.append(Probe(name: "toolbar \(type(of: navigation.topViewController!))",
                                        bar: navigation.toolbar, content: content, area: band))
                }
            }
            if let tabs = controller as? UITabBarController {
                tabs.selectedViewController.map(visit)
            } else {
                controller.children.forEach(visit)
            }
            controller.presentedViewController.map(visit)
        }
        window.rootViewController.map(visit)
        return probes
    }
}
#endif
