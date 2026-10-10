#if DEBUG
import CoreModels
import CoreNavigation
import CoreStorage
import DesignSystem
import FeedInterface
import MediaCore
import MediaPlayback
import PostGrid
import ShareSheet
import UIKit

// MARK: - QA hooks
//
// The launch-argument drivers stay in `PlaceProfileViewController.swift`
// (`scheduleDebugDrivesIfRequested`) and so does the `debug*` accessor
// extension: both read this screen's private state, which a file of its own
// could only reach by widening it. What lives here needs none of it.

extension PlaceProfileViewController {
    /// `-maps-place-pop-demo`: see `scheduleDebugDrivesIfRequested`.
    func scheduleDebugPopIfRequested() {
        guard !didScheduleDebugPop,
              ProcessInfo.processInfo.arguments.contains("-maps-place-pop-demo")
        else { return }
        didScheduleDebugPop = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, let nav = self.navigationController,
                  nav.topViewController === self else { return }
            nav.popViewController(animated: true)
        }
    }

    /// One frame of `-place-scroll-sweep`: 0 → 240pt → 0, eased, 3s a leg.
    func debugSweepStep(began: CFTimeInterval, probe: HeroScrollFrameProbe) {
        let t = CACurrentMediaTime() - began
        guard t < 6 else { return probe.finish() }
        let leg = t < 3 ? t / 3 : (6 - t) / 3
        probe.frame { debugScrollActivePage(to: CGFloat(240 * leg * leg * (3 - 2 * leg))) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self] in
            self?.debugSweepStep(began: began, probe: probe)
        }
    }

    /// One frame of `-place-stretch-sweep` (`HeroStretchSweep`).
    func debugStretchStep(
        began: CFTimeInterval, probe: HeroScrollFrameProbe, phase: HeroStretchSweep.Phase?
    ) {
        guard let (now, offset) = HeroStretchSweep.at(CACurrentMediaTime() - began) else { return probe.finish() }
        if now != phase { probe.beginPhase(now.rawValue) }
        probe.frame { debugScrollActivePage(to: offset) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self] in
            self?.debugStretchStep(began: began, probe: probe, phase: now)
        }
    }
}
#endif
