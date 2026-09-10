import DesignSystem
import UIKit

#if DEBUG

/// `-accessory-collapse-probe` — publishes the state of the tab bar's bottom
/// band, so a UITest with a REAL FINGER can say whether it minimizes.
///
/// # Why a probe and not an assertion in the app
///
/// ⚠️ **THE MINIMIZE DOES NOT ANSWER TO `setContentOffset`.** The first version
/// of this check lived inside `-header-audit`: it scrolled the registered scroll
/// view programmatically and read the band afterwards. Measured on all three
/// accessory surfaces, For You included — the one the viewer had already
/// confirmed collapsing on a real iPhone:
///
///     forYou:   env=regular accessory=360 barH=83 → env=regular accessory=360 barH=83
///     messages: env=regular accessory=360 barH=83 → env=regular accessory=360 barH=83
///     profile:  env=regular accessory=360 barH=83 → env=regular accessory=360 barH=83
///
/// So a scripted scroll reports a working screen as broken. UIKit drives the
/// minimize off a DRAG, and the only thing in this repo that produces one is an
/// XCUITest gesture — hence the app→test probe channel, exactly as
/// `HeroTransitionAudit` does it.
///
/// ⚠️ **AND `tabBar.frame` IS NOT THE SIGNAL EITHER.** It reads 402x83 minimized
/// and 402x83 not; UIKit keeps the band's frame and re-lays out inside it. What
/// moves is the accessory's ENVIRONMENT TRAIT — `.regular` at 360pt wide,
/// `.inline` at 234 docked beside the shrunken bar. A check reading the height
/// finds nothing on a screen that is working perfectly.
@MainActor
final class AccessoryCollapseAudit {
    private(set) static var shared: AccessoryCollapseAudit?

    static func installIfRequested(tabBarController: UITabBarController) {
        guard ProcessInfo.processInfo.arguments.contains("-accessory-collapse-probe"),
              shared == nil
        else { return }
        shared = AccessoryCollapseAudit(tabBarController: tabBarController)
    }

    private let tabBarController: UITabBarController
    private let probe = UIView(frame: CGRect(x: 0, y: 120, width: 2, height: 2))
    private let sinkURL: URL
    private var sink: FileHandle?
    private var timer: Timer?
    private var sequence = 0
    private var lastLine = ""

    private init(tabBarController: UITabBarController) {
        self.tabBarController = tabBarController
        sinkURL = URL.documentsDirectory.appendingPathComponent("accessory-collapse.log")
        try? Data().write(to: sinkURL)
        sink = try? FileHandle(forWritingTo: sinkURL)
        probe.backgroundColor = .clear
        probe.isAccessibilityElement = true
        probe.accessibilityLabel = "accessory collapse audit"
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        // `.common`: the default mode pauses timers while a finger is down, and
        // a finger being down is the entire subject.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        emit("[accessory-collapse] START sink=\(sinkURL.path)")
    }

    private func sample() {
        sequence += 1
        attachProbeIfNeeded()

        let content: UIView? = tabBarController.bottomAccessory?.contentView
        let top = topViewController
        let named = top?.contentScrollView(for: .bottom)
        let onScreen = top?.view.flatMap { OnScreenScroller.candidate(in: $0) }
        let line = "accessory;seq=\(sequence)"
            + ";env=\(environment(of: content))"
            + String(format: ";w=%.0f;container=%.0fx%.0f;containerX=%.0f;barH=%.0f",
                     content?.bounds.width ?? -1,
                     content?.superview?.bounds.width ?? -1,
                     content?.superview?.bounds.height ?? -1,
                     content?.superview.map { view in
                         view.convert(view.bounds, to: nil).minX
                     } ?? -1,
                     tabBarController.tabBar.bounds.height)
            + ";armed=\(tabBarController.tabBarMinimizeBehavior == .onScrollDown ? 1 : 0)"
            + ";named=\(named == nil ? 0 : 1)"
            + ";onscreen=\(named != nil && named === onScreen ? 1 : 0)"
            + String(format: ";offset=%.0f;room=%.0f", named?.contentOffset.y ?? -9999,
                     named.map { $0.contentSize.height - $0.bounds.height
                         + $0.adjustedContentInset.top + $0.adjustedContentInset.bottom } ?? -1)
            + ";segments=\(segmentWidths(in: content))"
            + ";surface=\(top.map { String(describing: type(of: $0)) } ?? "none")"
        probe.accessibilityIdentifier = line
        // Only transitions, so the sink is readable: 4Hz for a whole test run is
        // thousands of identical lines, and the one that matters is the one
        // where `env` changed. Compared with the volatile numbers stripped out: `seq` bumps every
        // sample and `offset` moves every frame of a drag, so leaving either in
        // makes "only transitions" mean "every sample".
        let comparable = line.split(separator: ";")
            .filter { !$0.hasPrefix("seq=") && !$0.hasPrefix("offset=") }
            .joined(separator: ";")
        if comparable != lastLine {
            lastLine = comparable
            emit(line)
        }
    }

    /// Each segment's width, in order — the number that says whether "All" is
    /// wearing "Requests"' box.
    private func segmentWidths(in content: UIView?) -> String {
        guard let content else { return "-" }
        var strip: PagedTabBar?
        func walk(_ view: UIView) {
            if let bar = view as? PagedTabBar { strip = strip ?? bar }
            view.subviews.forEach(walk)
        }
        walk(content)
        guard let strip else { return "-" }
        return strip.debugSegmentWidths.map { String(format: "%.0f", $0) }.joined(separator: "/")
    }

    private func environment(of content: UIView?) -> String {
        guard let content else { return "no-accessory" }
        switch content.traitCollection.tabAccessoryEnvironment {
        case .regular: return "regular"
        case .inline: return "inline"
        case .none: return "none"
        default: return "unspecified"
        }
    }

    private var topViewController: UIViewController? {
        var candidate = tabBarController.selectedViewController
        if let nav = candidate as? UINavigationController {
            candidate = nav.presentedViewController ?? nav.topViewController
        }
        return candidate
    }

    /// ⚠️ RE-ATTACHED EVERY SAMPLE, not once. The key window changes (a presented
    /// sheet, a fresh window scene) and a probe left in the old one is a probe
    /// the test cannot find — which reads as "the app never published" rather
    /// than "the probe moved".
    private func attachProbeIfNeeded() {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow })
        else { return }
        if probe.superview !== window { window.addSubview(probe) }
        window.bringSubviewToFront(probe)
    }

    private func emit(_ text: String) {
        print(text)
        sink?.write(Data((text + "\n").utf8))
    }
}
#endif
