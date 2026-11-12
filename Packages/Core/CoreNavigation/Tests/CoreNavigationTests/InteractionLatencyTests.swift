import QuartzCore
import Testing
import UIKit
@testable import CoreNavigation

/// `-interaction-latency` (#2116): the clock runs from the input's own
/// timestamp to the frame that shows the strongest response, and names the
/// turns and the waiting in between.
@MainActor
struct InteractionLatencyTrackerTests {
    typealias Tracker = InteractionLatencyTracker

    @Test func theClockRunsFromTheInputToTheFrame() throws {
        var tracker = Tracker()
        _ = tracker.begin(.init(kind: "tap", target: "button", at: 10))
        tracker.turnEnded(start: 10.004, end: 10.010)
        tracker.respond("appear:Profile", strength: .screen, at: 10.020)
        tracker.turnEnded(start: 10.015, end: 10.030)
        #expect(tracker.needsFrame)
        tracker.frame(vsync: 10.025, target: 10.033)
        #expect(tracker.needsFrame, "a frame whose vsync precedes the commit cannot show it")
        tracker.frame(vsync: 10.033, target: 10.041)
        let finished = tracker.finish()
        let record = try #require(finished)
        #expect(abs(record.latencyMs - 41) < 0.01)
        #expect(abs(record.commitMs - 30) < 0.01)
        #expect(record.turns == 2)
        #expect(abs(record.busyMs - 21) < 0.01)
        #expect(abs(record.idleMs - 9) < 0.01)
        #expect(abs(record.worstTurnMs - 15) < 0.01)
    }

    /// A button's action at once, then the push behind an await: the push is
    /// the response the rule is about; the action stays as the first.
    @Test func aLaterStrongerResponseIsTheOneMeasured() throws {
        var tracker = Tracker()
        _ = tracker.begin(.init(kind: "tap", target: "row", at: 0))
        tracker.respond("action:open@UIButton", strength: .action, at: 0.005)
        tracker.turnEnded(start: 0.002, end: 0.008)
        tracker.frame(vsync: 0.008, target: 0.016)
        tracker.respond("animation:opacity", strength: .animation, at: 0.05)
        tracker.respond("appear:Detail", strength: .screen, at: 0.180)
        tracker.turnEnded(start: 0.175, end: 0.190)
        tracker.frame(vsync: 0.191, target: 0.200)
        let finished = tracker.finish()
        let record = try #require(finished)
        #expect(record.response == "appear:Detail")
        #expect(abs(record.latencyMs - 200) < 0.01)
        #expect(record.firstResponse == "action:open@UIButton")
        #expect(abs(record.firstLatencyMs - 16) < 0.01)
        #expect(record.idleMs > 150, "the await before the push is waiting, not work: \(record.idleMs)")
    }

    /// The frame comes from the display's phase, not from the main thread:
    /// a hang after the commit does not delay what the render server shows.
    @Test func theFrameIsTheVsyncAfterTheCommitPlusOne() throws {
        #expect(abs(Tracker.presented(commit: 1.005, vsync: 1.0, period: 0.01) - 1.02) < 1e-9)
        #expect(abs(Tracker.presented(commit: 1.0, vsync: 1.0, period: 0.01) - 1.01) < 1e-9)
        #expect(abs(Tracker.presented(commit: 1.034, vsync: 1.0, period: 0.01) - 1.05) < 1e-9)
        var tracker = Tracker()
        _ = tracker.begin(.init(kind: "tap", target: "tab", at: 0))
        tracker.respond("appear:Map", strength: .screen, at: 0.05)
        tracker.turnEnded(start: 0.01, end: 0.06, presentedAt: 0.075)
        #expect(!tracker.needsFrame)
        let finished = tracker.finish()
        let record = try #require(finished)
        #expect(abs(record.latencyMs - 75) < 0.01)
    }

    @Test func anInputWithNoResponseLeavesNoRecord() {
        var tracker = Tracker()
        _ = tracker.begin(.init(kind: "tap", target: "nothing", at: 0))
        tracker.turnEnded(start: 0.001, end: 0.004)
        let finished = tracker.finish()
        #expect(finished == nil)
        #expect(tracker.input == nil)
    }

    @Test func theNextInputFinishesThePreviousOne() throws {
        var tracker = Tracker()
        _ = tracker.begin(.init(kind: "tap", target: "a", at: 0))
        tracker.respond("action:x@UIButton", strength: .action, at: 0.001)
        tracker.turnEnded(start: 0, end: 0.002)
        let next = tracker.begin(.init(kind: "tap", target: "b", at: 1))
        let flushed = try #require(next)
        #expect(flushed.input.target == "a")
        #expect(tracker.input?.target == "b")
    }

    /// A response before the input (a previous animation) is not its own.
    @Test func aResponseBeforeTheInputIsIgnored() {
        var tracker = Tracker()
        _ = tracker.begin(.init(kind: "tap", target: "a", at: 5))
        tracker.respond("appear:Old", strength: .screen, at: 4.9)
        tracker.turnEnded(start: 5.0, end: 5.01)
        let finished = tracker.finish()
        #expect(finished == nil)
    }

    /// A fling: the scroll moving on is the response, on the next frame.
    /// The animation it ends on, hundreds of ms later, is not (the device
    /// run of 2026-11-05 read 300–875 ms OVERs from those).
    @Test func aFlingIsNotAnsweredByTheAnimationItEndsOn() throws {
        var tracker = Tracker()
        _ = tracker.begin(.init(kind: "release", target: "feed", at: 0))
        tracker.respond("animation:opacity", strength: .animation, at: 0.004)
        tracker.dropAnimations()
        tracker.turnEnded(start: 0.001, end: 0.006)
        tracker.respond("animation:match-corner-radius", strength: .animation, at: 0.65)
        tracker.turnEnded(start: 0.64, end: 0.66)
        let fling = tracker.finish()
        #expect(fling == nil, "a fling with only animations leaves no record")

        _ = tracker.begin(.init(kind: "release", target: "feed", at: 1))
        tracker.dropAnimations()
        tracker.respond("appear:Detail", strength: .screen, at: 1.05)
        tracker.turnEnded(start: 1.04, end: 1.06, presentedAt: 1.07)
        let afterFling = tracker.finish()
        let screen = try #require(afterFling, "an action or a screen still counts")
        #expect(screen.response == "appear:Detail")

        _ = tracker.begin(.init(kind: "release", target: "card", at: 2))
        tracker.respond("animation:spring", strength: .animation, at: 2.01)
        tracker.turnEnded(start: 2.0, end: 2.02, presentedAt: 2.03)
        let next = tracker.finish()
        let spring = try #require(next, "the next release starts clean")
        #expect(spring.response == "animation:spring")
    }

    /// The keyboard's own controllers are not screens: its dismissal calls
    /// their `viewWillDisappear` as the slide ends (408–596 ms on device).
    /// The system's screens an app shows still are.
    @Test func theSystemsPlumbingIsNotAScreen() {
        for name in ["UIInputWindowController", "UICompatibilityInputViewController", "_UICursorAccessoryViewController",
                     "UIPredictionViewController", "_UISceneHostingViewController", "UITrackingElementWindowController",
                     "UIEditingOverlayViewController", "PrewarmingViewController"] {
            #expect(InteractionLatency.isSystemPlumbing(name: name, isSystem: true), "\(name)")
        }
        for name in ["UIViewController", "UINavigationController", "_UIContextMenuActionsOnlyViewController",
                     "UIAlertController", "UIActivityViewController", "PHPickerViewController",
                     "UIHostingController<AnyView>", "SFSafariViewController", "UISearchController"] {
            #expect(!InteractionLatency.isSystemPlumbing(name: name, isSystem: true), "\(name) is a screen")
        }
        #expect(!InteractionLatency.isSystemPlumbing(name: "PrewarmingViewController", isSystem: false),
                "the app's own controllers are screens whatever their name")
        #expect(!InteractionLatency.isSystemPlumbing(UIViewController()))
    }

    /// A swipe back let go: the screen reports at the end of the animation,
    /// after a wait. A slow screen behind a release shows busy time instead.
    @Test func aReleaseWhoseScreenCameAfterAWaitIsAnInteractiveEnd() {
        func record(kind: String, strength: Tracker.Strength, commit: Double, idle: Double) -> Tracker.Record {
            Tracker.Record(input: .init(kind: kind, target: "", at: 0), response: "appear:X", strength: strength,
                           latencyMs: commit + 20, commitMs: commit, turns: 2, busyMs: commit - idle, idleMs: idle,
                           worstTurnMs: 0, firstResponse: "animation:opacity", firstLatencyMs: 60)
        }
        #expect(InteractionLatency.isInteractiveEnd(record(kind: "release", strength: .screen, commit: 537, idle: 485)))
        #expect(!InteractionLatency.isInteractiveEnd(record(kind: "release", strength: .screen, commit: 300, idle: 60)),
                "busy, not waiting: a slow screen")
        #expect(!InteractionLatency.isInteractiveEnd(record(kind: "tap", strength: .screen, commit: 537, idle: 485)))
        #expect(!InteractionLatency.isInteractiveEnd(record(kind: "release", strength: .animation, commit: 537, idle: 485)))
    }

    /// A tap in a thread, then a swipe back: the inbox appears while the
    /// swipe's finger is down, and is the swipe's, not the tap's (the owner's
    /// device run of 2026-11-05 read 558–700 ms "closes" from it).
    @Test func whatHappensOnceTheNextTouchIsDownIsNotThePreviousInputs() throws {
        var tracker = Tracker()
        _ = tracker.begin(.init(kind: "tap", target: "thread", at: 0))
        tracker.respond("tap-recognizer@Thread", strength: .action, at: 0.06)
        tracker.stopResponses()
        tracker.turnEnded(start: 0.05, end: 0.07, presentedAt: 0.08)
        tracker.respond("appear:Inbox", strength: .screen, at: 0.5)
        tracker.turnEnded(start: 0.49, end: 0.52, presentedAt: 0.53)
        let finished = tracker.finish()
        let record = try #require(finished, "what it had still commits")
        #expect(record.response == "tap-recognizer@Thread")
        #expect(abs(record.latencyMs - 80) < 0.01)

        _ = tracker.begin(.init(kind: "tap", target: "row", at: 1))
        tracker.respond("appear:Thread", strength: .screen, at: 1.05)
        tracker.turnEnded(start: 1.04, end: 1.06, presentedAt: 1.07)
        let next = tracker.finish()
        #expect(next?.response == "appear:Thread", "the next input takes responses again")
    }

    /// A pulse or a looping avatar runs whatever the finger does.
    @Test func aRepeatingAnimationIsNobodysResponse() {
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.repeatCount = .infinity
        let sweep = CABasicAnimation(keyPath: "position")
        sweep.repeatDuration = 10
        #expect(InteractionLatency.isAmbient(pulse))
        #expect(InteractionLatency.isAmbient(sweep))
        #expect(!InteractionLatency.isAmbient(CABasicAnimation(keyPath: "bounds")))
    }

    @Test func theWindowEndsTheInputOnceItsFrameIsIn() {
        var tracker = Tracker(window: 2)
        _ = tracker.begin(.init(kind: "tap", target: "a", at: 0))
        tracker.respond("appear:A", strength: .screen, at: 0.01)
        tracker.turnEnded(start: 0, end: 0.02)
        let early = tracker.expire(now: 1)
        #expect(early == nil)
        let owed = tracker.expire(now: 2.5)
        #expect(owed == nil, "the frame is still owed")
        tracker.frame(vsync: 0.03, target: 0.04)
        let done = tracker.expire(now: 2.5)
        #expect(done != nil)
    }
}

/// The harness on a live stack: a synthetic input, a response deferred by a
/// `Task`, a `main.async` or work on the main thread, read back at its frame.
///
/// ⚠️ `.serialized`: the harness is one global clock.
@Suite(.serialized)
@MainActor
struct InteractionLatencyHarnessTests {
    private func stack() -> (UIWindow, UINavigationController) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let nav = UINavigationController(rootViewController: UIViewController())
        window.rootViewController = nav
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return (window, nav)
    }

    /// Waits for the response to be COMMITTED, then ends the input itself.
    /// Nothing hangs on the harness's own window, which the suite lengthens
    /// so it never drops a late response.
    ///
    /// A budget of LOOKS, not a clock: a look is spent only when the loop
    /// runs, so the wait stretches with a starved main actor (a CI simulator
    /// under parallel suites can starve it for minutes) where a wall-clock
    /// deadline would expire during the starvation. 24,000 looks of 10 ms
    /// are at least 240 s.
    private func responseCommitted(after count: Int) async -> Bool {
        for _ in 0..<24_000 where !InteractionLatency.hasCommittedResponse && InteractionLatency.records.count <= count {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return InteractionLatency.hasCommittedResponse || InteractionLatency.records.count > count
    }

    private func nextRecord(after count: Int) async throws -> InteractionLatencyTracker.Record {
        let committed = await responseCommitted(after: count)
        #expect(committed, "no response committed within the budget: \(InteractionLatency.debugState)")
        // One more turn for the frame's phase to be read, then the end.
        try await Task.sleep(for: .milliseconds(50))
        if InteractionLatency.records.count <= count { InteractionLatency.finishInput() }
        return try #require(InteractionLatency.records.dropFirst(count).first, "no record: \(InteractionLatency.debugState)")
    }

    private final class Destination: UIViewController {}

    /// Only this suite's own controllers and controls answer: other suites
    /// push and tap in the same process meanwhile.
    private func install() {
        InteractionLatency.install(log: false, hud: false)
        InteractionLatency.countsOnly = { $0 is Destination || $0 is UIButton }
        // Longer than any starvation: a CI runner under parallel suites once
        // held the main actor past a 60 s window, and the input was dropped
        // with "no response" before the deferred push could land. The test
        // ends the input itself (`nextRecord`), so the window never decides.
        InteractionLatency.responseWindow = 600
    }

    /// Nothing is hooked without the argument.
    @Test func itInstallsNothingUnlessAsked() {
        let before = InteractionLatency.isInstalled
        InteractionLatency.installIfRequested(arguments: ["app"])
        #expect(InteractionLatency.isInstalled == before)
    }

    @Test func aPushDeferredByAnAwaitIsMeasuredFromTheInput() async throws {
        install()
        let (window, nav) = stack()
        defer {
            window.isHidden = true
            InteractionLatency.responseWindow = 1.2
        }
        let count = InteractionLatency.records.count
        InteractionLatency.noteInput(kind: "tap", target: "test-await")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            nav.pushViewController(Destination(), animated: true)
        }
        let record = try await nextRecord(after: count)
        #expect(record.input.target == "test-await")
        #expect(record.response.contains("Destination"), "\(record.response)")
        #expect(record.latencyMs >= 120, "\(record.latencyMs)")
        // The await is waiting, not work: idle here, unless other suites keep
        // the main thread busy meanwhile — then it is their turns. Either
        // way the commit cannot come before the push.
        #expect(record.commitMs >= 120, "\(record.commitMs)")
        #expect(record.idleMs + record.busyMs >= 110, "idle \(record.idleMs) busy \(record.busyMs)")
        #expect(record.latencyMs >= record.commitMs)
    }

    @Test func aPushAfterBusyMainWorkCountsTheWork() async throws {
        install()
        let (window, nav) = stack()
        defer {
            window.isHidden = true
            InteractionLatency.responseWindow = 1.2
        }
        let count = InteractionLatency.records.count
        InteractionLatency.noteInput(kind: "tap", target: "test-busy")
        DispatchQueue.main.async {
            let until = CACurrentMediaTime() + 0.15
            while CACurrentMediaTime() < until {}
            nav.pushViewController(Destination(), animated: true)
        }
        let record = try await nextRecord(after: count)
        #expect(record.input.target == "test-busy")
        #expect(record.response.contains("Destination"), "\(record.response)")
        #expect(record.latencyMs >= 150, "\(record.latencyMs)")
        #expect(record.busyMs >= 140, "the work on main is busy time: \(record.busyMs)")
        #expect(record.worstTurnMs >= 140)
    }

    /// Off, the latency harness records nothing; paused (the dashboard up),
    /// the app's taps are not measured.
    @Test func switchedOffOrPausedItRecordsNothing() {
        InteractionLatency.install(log: false, hud: false)
        let wasActive = InteractionLatency.isActive
        defer { InteractionLatency.setActive(wasActive, badge: false) }
        InteractionLatency.setActive(false, badge: false)
        let count = InteractionLatency.records.count
        InteractionLatency.noteInput(kind: "tap", target: "off")
        InteractionLatency.noteResponse("appear:Off")
        InteractionLatency.finishInput()
        #expect(InteractionLatency.records.count == count, "recorded while off")
        InteractionLatency.setActive(true, badge: false)
        InteractionLatency.isPaused = true
        InteractionLatency.noteInput(kind: "tap", target: "paused")
        InteractionLatency.noteResponse("appear:Paused")
        InteractionLatency.finishInput()
        InteractionLatency.isPaused = false
        #expect(InteractionLatency.records.count == count, "recorded while the dashboard was up")
    }

    /// An action at once is an action-strength response within a frame or two.
    @Test func aControlActionAnswersAtItsOwnTurn() async throws {
        install()
        let (window, nav) = stack()
        defer {
            window.isHidden = true
            InteractionLatency.responseWindow = 1.2
        }
        let button = UIButton(type: .system)
        button.addAction(UIAction { _ in }, for: .touchUpInside)
        nav.topViewController?.view.addSubview(button)
        let count = InteractionLatency.records.count
        InteractionLatency.noteInput(kind: "tap", target: "test-action")
        button.sendActions(for: .touchUpInside)
        let record = try await nextRecord(after: count)
        #expect(record.input.target == "test-action")
        #expect(record.strength == .action, "\(record.response)")
        // Answered in its own turn: no wall-clock bound, which a starved CI
        // simulator would break, but the shape — one turn, no waiting hop.
        #expect(record.turns <= 1, "turns \(record.turns)")
        #expect(record.idleMs < record.busyMs + 50, "idle \(record.idleMs) busy \(record.busyMs)")
    }
}
