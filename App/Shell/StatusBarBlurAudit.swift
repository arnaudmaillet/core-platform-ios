import DesignSystem
import UIKit

#if DEBUG

/// `-status-bar-blur-audit` — whether the window's status-band blur
/// (`StatusBarBlurView`) is THERE, every frame, and what else blurs the band.
///
/// Every frame (cheap facts only), printed on change:
///
///     [sbb] +5310ms top=ForYouViewController moving band=on front=Y h=62 style=light own=1 offscreen=0
///
/// `band=on` = installed and not hidden; `front=Y` = no window sibling draws
/// over it (`zPosition`); `h` = the height its edge effect covers; `own` = the
/// backdrop layers inside the band (1 in light, 2 in dark); `offscreen` = its
/// `HeroScrollFrameProbe.Census` count. A frame with `band=off` or `front=N`
/// while a transition runs is the flash the window install exists to prevent.
///
/// And whenever the top screen changes, once it has landed, every backdrop
/// layer in the window that reaches into the status band — the band's own,
/// and any blur under it (MapKit's, a list that kept its edge effect):
///
///     [sbb] stack top=MapsViewController backdrops=3
///     [sbb]   StatusBarBlurView>_UIScrollEdgeEffectView y=0 h=62 variableBlur
///     [sbb]   _MKMapContentView y=0 h=62 variableBlur
///
/// Private filter names are read by key-value coding (`name`): DEBUG only.
/// The owner is the innermost view drawing the layer; `StatusBarBlurView>`
/// marks the band's own.
@MainActor
final class StatusBarBlurAudit {
    private static var shared: StatusBarBlurAudit?

    static func installIfRequested(in window: UIWindow) {
        guard ProcessInfo.processInfo.arguments.contains("-status-bar-blur-audit"), shared == nil else { return }
        shared = StatusBarBlurAudit(window: window)
    }

    private let window: UIWindow
    private let start = CACurrentMediaTime()
    private var link: CADisplayLink?
    private var lastFrame = ""
    private var lastStack = ""

    private init(window: UIWindow) {
        self.window = window
        let link = CADisplayLink(target: Proxy(self), selector: #selector(Proxy.tick))
        link.add(to: .main, forMode: .common)
        self.link = link
        Self.log("[sbb] START")
    }

    private final class Proxy: NSObject {
        weak var owner: StatusBarBlurAudit?
        init(_ owner: StatusBarBlurAudit) { self.owner = owner }
        @objc func tick() { MainActor.assumeIsolated { owner?.sample() } }
    }

    /// Unbuffered: `print` from an app that never exits reads empty from a
    /// file sink (`sim-log-capture-traps`).
    private static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    private func sample() {
        let (top, moving) = topScreen()
        var line = "top=\(top) \(moving ? "moving" : "rest")"
        if let band = StatusBarBlurView.installed(in: window) {
            let front = window.subviews.allSatisfy { $0 === band || $0.layer.zPosition < band.layer.zPosition }
            let backdrops = Self.backdrops(in: band.layer, window: window)
            let height = backdrops.map(\.frame.maxY).max() ?? 0
            let style = band.traitCollection.userInterfaceStyle == .dark ? "dark" : "light"
            let census = HeroScrollFrameProbe.Census(of: band.layer)
            line += " band=\(band.isHidden ? "off" : "on") front=\(front ? "Y" : "N") h=\(Int(height.rounded()))"
                + " style=\(style) own=\(backdrops.count) offscreen=\(census.offscreen)"
        } else {
            line += " band=none"
        }
        if line != lastFrame {
            lastFrame = line
            Self.log("[sbb] +\(Int((CACurrentMediaTime() - start) * 1000))ms \(line)")
        }
        // The whole-window walk only once the stack has landed on a new top.
        guard !moving, top != lastStack else { return }
        lastStack = top
        let all = Self.backdrops(in: window.layer, window: window).filter { $0.frame.minY < window.safeAreaInsets.top }
        Self.log("[sbb] stack top=\(top) backdrops=\(all.count)")
        for backdrop in all {
            Self.log("[sbb]   \(backdrop.owner) y=\(Int(backdrop.frame.minY)) h=\(Int(backdrop.frame.height)) \(backdrop.filters)")
        }
    }

    /// The screen on top — the frontmost presentation, through containers —
    /// and whether a transition is under way.
    private func topScreen() -> (String, Bool) {
        var controller = window.rootViewController
        var moving = false
        while let current = controller {
            if current.transitionCoordinator != nil { moving = true }
            if let presented = current.presentedViewController, !presented.isBeingDismissed {
                controller = presented
            } else if let nav = current as? UINavigationController {
                guard let next = nav.topViewController else { break }
                controller = next
            } else if let tabs = current as? UITabBarController {
                guard let next = tabs.selectedViewController else { break }
                controller = next
            } else if let child = current.children.last(where: { $0.viewIfLoaded?.window != nil }),
                      current.presentedViewController == nil {
                controller = child
            } else {
                break
            }
        }
        return (controller.map { String(describing: type(of: $0)) } ?? "?", moving)
    }

    private struct Backdrop {
        var owner: String
        var frame: CGRect
        var filters: String
    }

    /// Every visible backdrop layer under `root`, framed in the window.
    private static func backdrops(in root: CALayer, window: UIWindow) -> [Backdrop] {
        var found: [Backdrop] = []
        let bandLayer = StatusBarBlurView.installed(in: window)?.layer
        func visit(_ layer: CALayer, owner: String, inBand: Bool) {
            guard !layer.isHidden, layer.opacity > 0 else { return }
            let inBand = inBand || layer === bandLayer
            let owner = (layer.delegate as? UIView).map { String(describing: type(of: $0)) } ?? owner
            if String(describing: type(of: layer)).contains("Backdrop") {
                let filters = (layer.filters ?? []).map { filter -> String in
                    let object = filter as AnyObject
                    guard object.responds(to: NSSelectorFromString("name")) else { return "?" }
                    return (object.value(forKey: "name") as? String) ?? "?"
                }.joined(separator: "+")
                let label = inBand ? "StatusBarBlurView>" + owner : owner
                found.append(Backdrop(owner: label, frame: layer.convert(layer.bounds, to: window.layer), filters: filters))
            }
            layer.sublayers?.forEach { visit($0, owner: owner, inBand: inBand) }
        }
        visit(root, owner: "?", inBand: false)
        return found
    }
}

#endif
