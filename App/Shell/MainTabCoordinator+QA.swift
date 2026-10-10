#if DEBUG
import ChatInterface
import CoreModels
import CoreNavigation
import FeedInterface
import MediaPlayback
import NotificationsInterface
import ProfileInterface
import UIKit
import DesignSystem
import Upload

// MARK: - QA hooks: launch arguments

extension MainTabCoordinator {
    /// The shell's DEBUG automation, run at the end of `start()`: the live
    /// audits, then every launch-argument hook. Kept out of the shell itself
    /// so the coordinator reads as the app; nothing here ships in Release.
    func installQAHooks() {
        // `-hero-audit`: the hero machinery's live census — pools, transition
        // objects, stranded views — published to an accessibility probe, a
        // file sink, and the console. The channel every Hero UI suite reads.
        HeroTransitionAudit.installIfRequested(pools: container.debugPlaybackPools)
        AccessoryCollapseAudit.installIfRequested(tabBarController: tabBarController)
        PillDragAudit.installIfRequested(tabBarController: tabBarController)
        DockTrace.installIfRequested(tabBarController: tabBarController)

        // Dev convenience: `-select-tab N` opens directly on a tab for testing,
        // in bar order (0 = Explore … 3 = Profile; the "+" is not a tab and has
        // no index). Every index is a plain selection now — 1 used to trigger
        // the feed push instead, which it no longer does; use `-open-feed` for
        // the timeline.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-select-tab"), index + 1 < arguments.count,
           let tabIndex = Int(arguments[index + 1]), AppTab.allCases.indices.contains(tabIndex) {
            selectTab(AppTab.allCases[tabIndex])
        }
        // `-switch-tab N` selects a tab a few seconds AFTER launch, which is a
        // different thing from `-select-tab N` and the difference is
        // load-bearing: `-select-tab` fires before the shell is in a window, so
        // the tab's navigation bar lays out once, already showing. A real viewer
        // arrives by switching, and the Messages selector collapsed into a `•••`
        // on exactly that path while `-select-tab` showed it hosted perfectly.
        // Pair with `-header-audit-current`.
        if let index = arguments.firstIndex(of: "-switch-tab"), index + 1 < arguments.count,
           let tabIndex = Int(arguments[index + 1]), AppTab.allCases.indices.contains(tabIndex) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.selectTab(AppTab.allCases[tabIndex])
            }
        }
        // `-open-feed` pushes the open-ended timeline — the `AppRoute.feed`
        // path, which no longer has a bar button behind it. Deferred a tick:
        // at `start()` the shell isn't the window root yet, so an immediate
        // push would animate off-window.
        if arguments.contains("-open-feed") {
            DispatchQueue.main.async { [weak self] in self?.openFeed() }
        }
        // `-open-my-profile` selects the Profile tab on launch. It used to push
        // the avatar's destination; the destination is now a root, so the intent
        // "show me my profile" is a selection. Deferred a tick: at `start()` the
        // shell isn't the window root yet.
        if arguments.contains("-open-my-profile") {
            DispatchQueue.main.async { [weak self] in self?.selectTab(.profile) }
        }
        // `-open-search` pushes the global search screen onto the current tab —
        // the `AppRoute.search` path both header magnifiers take. The simulator
        // injects no taps, so this is the only way to reach that screen, and its
        // keyboard, headlessly. Pair with `-select-tab` to choose the origin.
        if arguments.contains("-open-search") {
            DispatchQueue.main.async { [weak self] in self?.container.router.route(to: .search) }
        }
        // `-open-create <camera|upload|text>` opens one of the "+" menu's
        // destinations on launch through the menu's own code path, minus the
        // menu. Deferred ~0.6s rather than a tick: a PRESENTATION from a
        // controller that is not in a window yet is refused outright.
        //
        // ⚠️ AND THEN GATED ON THAT STATE, because 0.6 s was only a guess at
        // it. On a slow boot the shell was still off-window (or the root swap
        // still running), UIKit refused the presentation, and `openCreate`'s
        // own `presentedViewController` guard turns away a second one — both
        // silently. The 0.6 s stays as the earliest moment, keeping the
        // composer's presentation off the launch's own turns; the hook then
        // waits for a shell in a window with nothing presented and no
        // transition running, and says GAVE UP if that never comes.
        if let index = arguments.firstIndex(of: "-open-create"), index + 1 < arguments.count,
           let destination = CreateTabItem.Destination(rawValue: arguments[index + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                QAWait.until("-open-create \(destination.rawValue)", { [weak self] in
                    guard let self else { return true }
                    return tabBarController.viewIfLoaded?.window != nil
                        && tabBarController.presentedViewController == nil
                        && tabBarController.transitionCoordinator == nil
                }) { [weak self] in
                    self?.openCreate(destination)
                }
            }
        }
        // `-open-create-menu`: the "+" MENU itself, through the very path a
        // tap takes (`shouldSelectTab`), ~1.5s in — the menu is a `UIMenu`
        // no simulator tap can open, and `-presentation-budget` needs its
        // presentation turn on its own, without a composer behind it.
        if arguments.contains("-open-create-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                _ = self.tabBarController(self.tabBarController, shouldSelectTab: self.createItem.tab)
            }
        }
        // `-plus-hold-demo <full|short|hold|drift>` holds the "+" through
        // `CreateHoldShortcut`'s own press path — the recogniser's `.began`,
        // `.changed` and `.ended` inputs, minus the recogniser, which no
        // simulator script can hold down — so the disc, its ring, the arming
        // and the camera opening can be filmed. Each step waits on the
        // shortcut's state, never on a clock (the pauses are pacing, so a
        // recording shows each state at rest), and prints GAVE UP if the
        // state never comes. `[plus-hold]` lines go to stderr.
        if let index = arguments.firstIndex(of: "-plus-hold-demo") {
            let mode = index + 1 < arguments.count ? arguments[index + 1] : "full"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.debugPlusHoldDemo(mode: mode)
            }
        }
        // `-nav-stress <cycles>` drives deep cyclical navigation and audits
        // what each round trip leaves behind — see `NavigationStressTest`. The
        // failure it hunts is a screen that looks correct and no longer answers
        // touches, which no screenshot can tell from a working one.
        if let position = arguments.firstIndex(of: "-nav-stress"),
           position + 1 < arguments.count, let cycles = Int(arguments[position + 1]) {
            let harness = NavigationStressTest(
                tabBarController: tabBarController,
                router: container.router,
                selectTab: { [weak self] tab in self?.selectTab(tab) }
            )
            // `-nav-stress <cycles> [tab]` — one tab by name, or every tab.
            let only = position + 2 < arguments.count
                ? AppTab(rawValue: arguments[position + 2]) : nil
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await harness.run(cycles: cycles, tabs: only.map { [$0] } ?? AppTab.allCases)
            }
        }
        // `-header-audit` visits every tab and checks the leading-group selector
        // layout on each: in the leading group, sized, hit-testable at every
        // segment, and — on a pushed surface — with the back button and the
        // interactive pop still intact. See `HeaderSelectorAudit`.
        if arguments.contains("-header-audit") {
            let audit = HeaderSelectorAudit(
                tabBarController: tabBarController,
                selectTab: { [weak self] tab in self?.selectTab(tab) }
            )
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                await audit.run(tabs: AppTab.allCases)
            }
        }
        // `-header-audit-current` audits only what is on screen. The tab sweep
        // cannot reach a PUSHED host — a profile, or the relationships screen —
        // and those are the only ones where the back button and the interactive
        // pop are at stake. Pair it with `-open-profile` / `-profile-relationships`.
        if arguments.contains("-header-audit-current") {
            let audit = HeaderSelectorAudit(
                tabBarController: tabBarController,
                selectTab: { [weak self] tab in self?.selectTab(tab) }
            )
            Task { @MainActor in
                // POLLS. A single fixed delay reported "no selector on this bar"
                // for surfaces that were hosting it perfectly — the screen simply
                // had not finished loading yet, and a slower boot moved the whole
                // run past the deadline. Two conclusions were drawn from that
                // before the harness was suspected. Waits for a selector, then
                // audits; if none ever arrives, audits anyway and says so.
                // Waits for a STABLE frame, not merely a present one. Measuring
                // the first non-zero frame caught selectors mid-push and reported
                // 334x43 and 28x7 for the same screen whose settled host is
                // 278x36 — an "escapes the clamp" anomaly that was the harness
                // reading an animation.
                var previous = CGRect.null
                var stableFrames = 0
                for _ in 0..<80 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    let frame = audit.selectorFrameOnScreen
                    if frame != .null, frame == previous {
                        stableFrames += 1
                        if stableFrames >= 2 { break }
                    } else {
                        stableFrames = 0
                    }
                    previous = frame
                }
                if arguments.contains("-header-bar-tree") { audit.dumpBarTree() }
                let finding = audit.audit(surface: "on-screen")
                for problem in finding.problems { print("[header-audit] on-screen: PROBLEM \(problem)") }
                if finding.isClean { print("[header-audit] on-screen: clean") }
            }
        }
        // `-open-notifications` opens the notifications drawer on launch — the
        // bells' exact code path — once the shell is in a window at rest on a
        // root (pair with `-select-tab N` for the main screen behind it).
        // `-notifications-progress <0…1.1>` instead HOLDS the drawer part-way,
        // as a finger would, for a still of a half-open state; above 1 shows
        // the rubber band. `-notifications-drag-demo` drives the tracking path
        // the edge swipe takes (minus the recogniser): a drag that falls back,
        // one that opens, then a drag back that closes. See
        // `debugNotificationsDrawerHooks`.
        debugNotificationsDrawerHooks(arguments)
        // `-feed-repush-demo` pushes the feed twice (combine with
        // `-snap-auto-dismiss`, which pops it ~2.5s after each landing): the
        // second push must resume where the first left off — the retained-
        // timeline continuity the sim can't demonstrate by tapping.
        //
        // ⚠️ EACH STEP WAITS FOR THE ONE BEFORE IT, not for a clock. The second
        // push used to fire at a fixed 7 s, which only worked while the first
        // landing + the 2.5 s auto-dismiss + the pop all fit inside it: under
        // Slow Animations (or without `-snap-auto-dismiss`) it landed on a
        // feed still on top — a no-op push, and a "continuity" run that
        // re-pushed nothing. Now: push once the stack is at rest, wait for
        // the landing, wait for the pop, push again; GAVE UP at any step
        // that never comes. The 1 s before the first push is the opening beat.
        if arguments.contains("-feed-repush-demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.debugPushFeedWhenResting("-feed-repush-demo first push") { [weak self] stack, feed in
                    QAWait.until(
                        "-feed-repush-demo pop of the first push (pair with -snap-auto-dismiss)",
                        timeout: 30, { [weak stack] in
                            guard let stack else { return true }
                            return stack.transitionCoordinator == nil
                                && !stack.viewControllers.contains(feed)
                        }
                    ) { [weak self] in
                        self?.debugPushFeedWhenResting("-feed-repush-demo second push") { _, _ in }
                    }
                }
            }
        }
        // `-feed-swipe-demo` pushes the feed, then drives the swipe-to-pop
        // twice: below the completion threshold (springs back), then past it
        // (pops home, bar returns) — the sim can't inject pans.
        //
        // ⚠️ The swipe used to fire at a fixed 3 s, 2 s after a push that
        // under Slow Animations had not landed yet — a swipe into a push in
        // flight. It now waits for the landing, then holds 1.5 s on the landed
        // feed (pacing, so a recording shows it at rest before the grab), and
        // swipes only if the feed is still on top at rest.
        if arguments.contains("-feed-swipe-demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.debugPushFeedWhenResting("-feed-swipe-demo") { stack, feed in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak stack] in
                        guard let self, let stack,
                              stack.topViewController === feed,
                              stack.transitionCoordinator == nil else {
                            QAWait.fail("-feed-swipe-demo", "the feed was not on top at rest when the swipe was due")
                            return
                        }
                        feedFlow?.debugScriptedSwipe()
                    }
                }
            }
        }
    }
}

// MARK: - QA hooks: waiting on the stack, not on a clock

extension MainTabCoordinator {
    /// The selected tab's stack, when the shell is on screen with nothing
    /// presented over it and no push or pop running on it — the only state a
    /// scripted push can be trusted to land from.
    fileprivate var debugRestingStack: UINavigationController? {
        guard tabBarController.viewIfLoaded?.window != nil,
              tabBarController.presentedViewController == nil,
              let stack = tabBarController.selectedViewController as? UINavigationController,
              stack.transitionCoordinator == nil else { return nil }
        return stack
    }

    /// The notifications drawer's launch hooks: see the note in `installQAHooks()`.
    fileprivate func debugNotificationsDrawerHooks(_ arguments: [String]) {
        let wantsOpen = arguments.contains("-open-notifications")
        let heldProgress = arguments.firstIndex(of: "-notifications-progress")
            .flatMap { $0 + 1 < arguments.count ? Double(arguments[$0 + 1]) : nil }
        let wantsDragDemo = arguments.contains("-notifications-drag-demo")
        guard wantsOpen || heldProgress != nil || wantsDragDemo else { return }
        let drawer = notificationsDrawer
        // Deferred past launch, then gated: the drawer only opens from a root
        // at rest in a window, and `-select-tab` lands after `start()`.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            QAWait.until("notifications drawer: a resting root in a window", { [weak self] in
                guard let self else { return true }
                return tabBarController.viewIfLoaded?.window != nil && drawer.edgeBelongsToDrawer
            }) {
                if let heldProgress {
                    drawer.container.debugHold(progress: CGFloat(heldProgress))
                } else if wantsDragDemo {
                    Self.debugRunDrawerDragDemo(drawer.container)
                } else {
                    drawer.open()
                }
            }
        }
    }

    /// Three drags through the gesture's own tracking path, each once the last
    /// has settled: to 30% released slowly (falls back shut), to 45% released
    /// with a rightward flick (opens), then back 60% with a leftward flick
    /// (closes). `[drawer-demo]` lines mark each step.
    private static func debugRunDrawerDragDemo(_ container: SideDrawerContainerViewController) {
        let log = { (line: String) in print("[drawer-demo] \(line)") }
        log("drag to 0.30, slow release")
        container.debugScriptedDrag(to: 0.30, duration: 0.8, releaseVelocity: 40) {
            QAWait.until("-notifications-drag-demo: closed after the short drag", { container.phase == .closed }) {
                log("closed; drag to 0.45, flick right")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    container.debugScriptedDrag(to: 0.45, duration: 0.5, releaseVelocity: 900) {
                        QAWait.until("-notifications-drag-demo: open after the flick", { container.phase == .open }) {
                            log("open; drag back to 0.40, flick left")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                container.debugScriptedDrag(to: 0.40, duration: 0.5, releaseVelocity: -900) {
                                    QAWait.until("-notifications-drag-demo: closed", { container.phase == .closed }) {
                                        log("closed; done")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Drives `-plus-hold-demo`: see the hook in `installQAHooks()`.
    fileprivate func debugPlusHoldDemo(mode: String) {
        let label = "-plus-hold-demo \(mode)"
        let hold = createHold
        QAWait.until("\(label): a resting shell with the + placed", { [weak self] in
            guard let self else { return true }
            return tabBarController.viewIfLoaded?.window != nil
                && tabBarController.presentedViewController == nil
                && tabBarController.transitionCoordinator == nil
                && hold.debugBubbleCentre != nil
        }) { [weak self] in
            // Pacing: a second of the bar at rest before the finger lands.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.debugRunPlusHold(mode: mode, label: label)
            }
        }
    }

    private func debugRunPlusHold(mode: String, label: String) {
        let hold = createHold
        // The shell's own controller, alive as long as the app: holding it
        // here keeps every step below free of `self`.
        let controller = tabBarController
        let presented = { controller.presentedViewController.map { "\(type(of: $0))" } ?? "nil" }
        hold.debugLog("\(label): press")
        hold.debugPress()
        switch mode {
        case "short":
            // Let go with the ring half full: the disc must shrink away and
            // nothing may open.
            QAWait.until("\(label): half a ring", { hold.debugProgress >= 0.5 }) {
                let disc = hold.debugDisc
                hold.debugLog(String(format: "\(label): release at %.2f", hold.debugProgress))
                hold.debugRelease()
                QAWait.until("\(label): the disc gone", { disc?.superview == nil }) {
                    hold.debugLog("\(label): disc gone, presented=\(presented())")
                }
            }
        case "drift":
            // Slide off with the ring under way: the disc goes at once, while
            // the finger is still down, and the lift then does nothing.
            QAWait.until("\(label): a ring under way", { hold.debugProgress >= 0.4 }) {
                hold.debugDrag(by: CGVector(dx: -90, dy: -30))
                QAWait.until("\(label): abandoned", { hold.debugPhase == .abandoned }) {
                    hold.debugLog("\(label): abandoned while held")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        hold.debugRelease()
                        hold.debugLog("\(label): released, presented=\(presented())")
                    }
                }
            }
        case "hold":
            // Stay armed, for a still of the full state.
            QAWait.until("\(label): armed", { hold.debugPhase == .armed }) {
                hold.debugLog("\(label): armed, holding")
            }
        default:
            // "full": fill, hold armed a beat, let go — the camera opens.
            QAWait.until("\(label): armed", { hold.debugPhase == .armed }) {
                hold.debugLog("\(label): armed")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    hold.debugRelease()
                    QAWait.until("\(label): the camera presented", { controller.presentedViewController != nil }) {
                        hold.debugLog("\(label): presented \(presented())")
                    }
                }
            }
        }
    }

    /// Pushes the timeline (`openFeed`, the bar's own path) once the selected
    /// stack is at rest, then hands `landed` that stack and the feed once the
    /// push has FINISHED — the stack deeper than it was and no transition
    /// running. Each wait prints a `[qa] GAVE UP` line if it never comes, so
    /// a demo that did not push, or whose push never landed, says so.
    fileprivate func debugPushFeedWhenResting(
        _ label: String,
        landed: @escaping @MainActor (UINavigationController, UIViewController) -> Void
    ) {
        QAWait.until("\(label): a resting stack to push on", { [weak self] in
            guard let self else { return true }
            return debugRestingStack != nil
        }) { [weak self] in
            guard let self, let stack = debugRestingStack else { return }
            let depth = stack.viewControllers.count
            openFeed()
            QAWait.until("\(label): the push landing", { [weak stack] in
                guard let stack else { return true }
                return stack.transitionCoordinator == nil && stack.viewControllers.count > depth
            }) { [weak stack] in
                guard let stack, let feed = stack.topViewController else { return }
                landed(stack, feed)
            }
        }
    }
}
#endif
