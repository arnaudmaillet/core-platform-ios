import UIKit

/// Probes points across each visible bar's area — tab bar, its accessory,
/// navigation bars, toolbars and the bars screens declared
/// (`BarTouchGuard.declareBar`) — and counts how many a TAP would reach in
/// the screen's content WITHOUT the shield ("raw") and WITH it ("guarded":
/// points the shield does not follow) (#562, #1145).
///
///     [bar-touch] tab bar {{0, 791}, {402, 83}} 60 probes: content raw=34 guarded=0 (MKMapView…)
///
/// "raw" > 0 is the leak #562 describes; "guarded" must be 0, the left edge
/// included. Items stay reachable: a probe the bar itself answers is never
/// counted. Pans are not the shield's: `BarTapShieldUITests` checks a pan
/// from the tab bar band still scrolls.
///
/// `BarTapShieldTests.theAuditFindsNoLeak` runs `measure` over a built screen
/// in DesignSystem's lane; `-bar-touch-audit` prints it every 3 s on the
/// running app.
@MainActor
public enum BarTouchAudit {
    /// One bar's count.
    public struct Measurement: Equatable, CustomStringConvertible {
        public let name: String
        public let frame: CGRect
        public let probes: Int
        /// Probes a tap would reach the content from, without the shield.
        public let raw: Int
        /// Of those, the probes the shield does not follow: the leak.
        public let guarded: Int
        /// The content views those probes hit.
        public let leaked: [String]

        public var description: String {
            "\(name) \(frame.integral) \(probes) probes: content raw=\(raw) guarded=\(guarded)"
                + (leaked.isEmpty ? "" : " (\(leaked.prefix(4).joined(separator: ", ")))")
        }
    }

    #if DEBUG
    private static var timer: Timer?

    /// `-bar-touch-audit`: prints every bar's measurement every 3 s.
    public static func startIfRequested(in window: UIWindow) {
        guard ProcessInfo.processInfo.arguments.contains("-bar-touch-audit"), timer == nil else { return }
        let timer = Timer(timeInterval: 3, repeats: true) { [weak window] _ in
            MainActor.assumeIsolated {
                guard let window else { return }
                for measurement in measure(in: window) { print("[bar-touch] \(measurement)") }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        Self.timer = timer
    }
    #endif

    private struct Probe {
        let name: String
        let bar: UIView
        let content: UIView
        /// The area probed, when it is not the bar's own frame.
        var area: CGRect?
    }

    /// Every bar on screen in `window`, measured.
    public static func measure(in window: UIWindow) -> [Measurement] {
        probes(in: window).map { probe in
            let frame = probe.area ?? probe.bar.convert(probe.bar.bounds, to: window)
            var raw = 0, guarded = 0, total = 0
            var leaked: Set<String> = []
            for point in samples(in: frame) {
                total += 1
                guard let hit = window.hitTest(point, with: nil) else { continue }
                // A tap starting here reaches content unless the shield follows it.
                let shielded = BarTouchGuard.bar(replacing: hit, at: point, in: window) != nil
                if hit.isDescendant(of: probe.content), !BarTouchGuard.isPart(hit, of: probe.bar) {
                    raw += 1
                    leaked.insert(String(describing: type(of: hit)))
                    if !shielded { guarded += 1 }
                }
            }
            return Measurement(name: probe.name, frame: frame, probes: total, raw: raw, guarded: guarded,
                               leaked: leaked.sorted())
        }
    }

    /// A grid over the bar, the left edge included (#1145).
    private static func samples(in frame: CGRect) -> [CGPoint] {
        var points: [CGPoint] = []
        for y in [frame.minY + 6, frame.midY, frame.maxY - 6] where frame.height > 12 {
            var x = frame.minX + 6
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
               let top = navigation.topViewController, let content = top.viewIfLoaded, content.window === window {
                if !navigation.isNavigationBarHidden {
                    probes.append(Probe(name: "nav bar \(type(of: top))", bar: navigation.navigationBar, content: content))
                }
                if let band = BarTouchGuard.toolbarBand(of: navigation, content: content, in: window) {
                    probes.append(Probe(name: "toolbar \(type(of: top))", bar: navigation.toolbar, content: content, area: band))
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
        for bar in BarTouchGuard.declaredBars(in: window) {
            guard let content = BarTouchGuard.screen(of: bar) else { continue }
            probes.append(Probe(name: "declared \(type(of: bar))", bar: bar, content: content))
        }
        return probes
    }
}
