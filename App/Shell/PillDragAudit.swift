import DesignSystem
import UIKit

#if DEBUG

/// `-pill-drag-probe` — publishes where the selection pill IS, so a UITest with
/// a real finger can aim at it and say what happened.
///
/// # Why a probe and not a unit test
///
/// The rule the pill drag rests on is about WHERE a touch lands: on the pill it
/// drags the pill, anywhere else on the capsule it scrolls the strip. Both
/// halves are arbitration between three recognizers — the grab, the strip's own
/// pan, and whatever the host has attached — and arbitration is the one thing a
/// unit test cannot exercise: a gesture recognizer needs a touch, and the
/// component's own tests drive the drag through debug hooks that skip the
/// recognizer entirely. Those tests pin the arithmetic; this pins that the
/// finger reaches it.
///
/// ⚠️ The pill's position is not derivable from the outside. Segment geometry is
/// `#if DEBUG` and expressed in the strip's own scrolled space, and the pill is
/// an interpolation between two segments rather than one of them — so a test
/// aiming at "the selected tab" by name would be aiming at the wrong rectangle
/// the moment the pages are mid-flight. The bar reports the rectangle it drew.
@MainActor
final class PillDragAudit {
    private(set) static var shared: PillDragAudit?

    static func installIfRequested(tabBarController: UITabBarController) {
        guard ProcessInfo.processInfo.arguments.contains("-pill-drag-probe"),
              shared == nil
        else { return }
        shared = PillDragAudit(tabBarController: tabBarController)
    }

    private let tabBarController: UITabBarController
    private let probe = UIView(frame: CGRect(x: 0, y: 160, width: 2, height: 2))
    private var timer: Timer?
    private var sequence = 0

    private init(tabBarController: UITabBarController) {
        self.tabBarController = tabBarController
        probe.backgroundColor = .clear
        probe.isAccessibilityElement = true
        probe.accessibilityLabel = "pill drag audit"
        // `.common`, because the default mode pauses timers while a finger is
        // down and a finger being down is the entire subject.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func sample() {
        sequence += 1
        attachProbeIfNeeded()
        guard let bar = visibleBar() else {
            probe.accessibilityIdentifier = "pill;seq=\(sequence);bar=0"
            return
        }
        let pill = bar.debugPillOnScreen
        let strip = bar.debugStripOnScreen
        stepDemoIfRequested(on: bar)
        probe.accessibilityIdentifier = "pill;seq=\(sequence);bar=1"
            + ";index=\(bar.selectedIndex);tabs=\(bar.debugSegmentCount)"
            + String(format: ";pill=%.0f,%.0f,%.0f,%.0f", pill.minX, pill.minY, pill.width, pill.height)
            + String(format: ";strip=%.0f,%.0f,%.0f,%.0f", strip.minX, strip.minY, strip.width, strip.height)
            + String(format: ";offset=%.0f;overflow=%.0f", bar.debugStripOffset, bar.debugOverflow)
            + ";grabs=\(bar.debugGrabsBegun);taps=\(bar.debugTapsReceived)"
            + ";begin=[\(bar.debugLastBeginTest)]"
    }

    // MARK: - The scripted drag

    /// `-pill-drag-demo` — drags the pill one segment and lets go, on a timer,
    /// so the whole loop can be WATCHED rather than asserted: the pill under
    /// the finger, the pages running with it, and the settle at the end.
    ///
    /// It enters through the bar's debug hooks, which is one step below the
    /// recognizer — the arbitration is `PillDragUITests`' subject, and this is
    /// the motion's. A screen recording is the only instrument for the second
    /// one, and a recording needs something to record.
    private var demo: (start: CGFloat, target: CGFloat, frame: Int)?

    private func stepDemoIfRequested(on bar: PagedTabBar) {
        guard ProcessInfo.processInfo.arguments.contains("-pill-drag-demo") else { return }
        let strip = bar.debugStripOnScreen
        let pill = bar.debugPillOnScreen
        guard strip.width > 0, pill.width > 0, bar.debugSegmentCount > 1 else { return }

        guard var run = demo else {
            // Start once the screen has settled — a drag begun into a layout
            // pass is a drag against a pill that is still moving.
            guard sequence > 20 else { return }
            let from = pill.midX - strip.minX
            let pitch = strip.width / CGFloat(bar.debugSegmentCount)
            // Towards the neighbour there is room for.
            let to = bar.selectedIndex == 0 ? from + pitch : from - pitch
            demo = (from, to, 0)
            _ = bar.debugBeginPillDrag(atViewportX: from)
            print("[pill-demo] begin at \(Int(from)) → \(Int(to))")
            return
        }
        run.frame += 1
        demo = run
        let frames = 18
        if run.frame <= frames {
            let travelled = run.start + (run.target - run.start) * CGFloat(run.frame) / CGFloat(frames)
            bar.debugDragPill(toViewportX: travelled)
        } else if run.frame == frames + 4 {
            bar.debugEndPillDrag()
            print("[pill-demo] released on index \(bar.selectedIndex)")
        }
    }

    /// The bar the viewer can actually touch.
    ///
    /// The accessory first, because that is where every root screen's selector
    /// lives now; then the top view controller's own view, which is where a
    /// pushed screen with `hidesBottomBarWhenPushed` keeps its own. A bar with
    /// no window, or one behind a presented screen, is not something a finger
    /// can reach and is not what this reports.
    private func visibleBar() -> PagedTabBar? {
        if let accessory = tabBarController.bottomAccessory?.contentView,
           let bar = firstBar(in: accessory) {
            return bar
        }
        var candidate = tabBarController.selectedViewController
        if let nav = candidate as? UINavigationController {
            candidate = nav.presentedViewController ?? nav.topViewController
        }
        return candidate?.view.flatMap(firstBar)
    }

    private func firstBar(in view: UIView) -> PagedTabBar? {
        if let bar = view as? PagedTabBar, bar.window != nil, !bar.isHidden { return bar }
        for subview in view.subviews {
            if let found = firstBar(in: subview) { return found }
        }
        return nil
    }

    /// ⚠️ RE-ATTACHED EVERY SAMPLE, for the reason `AccessoryCollapseAudit`
    /// records: the key window changes, and a probe left in the old one reads as
    /// "the app never published".
    private func attachProbeIfNeeded() {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow })
        else { return }
        if probe.superview !== window { window.addSubview(probe) }
        window.bringSubviewToFront(probe)
    }
}
#endif
