import Testing
import UIKit
@testable import DesignSystem

/// Decoration rests once nobody touches the app, and wakes on the next
/// touch (#580). The monitor here never flips the app-wide `IdleCalm`: it
/// reports to a recorder, so suites running beside it are left alone.
@MainActor
struct IdleCalmTests {
    /// A monitor on a hand-wound clock: its deadlines are collected, and the
    /// test fires them — time never runs on its own, so a starved runner
    /// cannot make two close touches far apart (#650's first CI run).
    private func makeMonitor() -> (IdleCalmMonitor, Recorder) {
        let monitor = IdleCalmMonitor()
        let recorder = Recorder()
        monitor.apply = { recorder.states.append($0) }
        monitor.schedule = { _, deadline in recorder.deadlines.append(deadline) }
        return (monitor, recorder)
    }

    private final class Recorder {
        var states: [Bool] = []
        var deadlines: [@MainActor () -> Void] = []

        /// The time runs out on every deadline set so far.
        @MainActor func passTime() {
            let due = deadlines
            deadlines = []
            due.forEach { $0() }
        }
    }

    @Test func nobodyTouchingRestsTheDecorationAndATouchWakesIt() {
        let (monitor, recorder) = makeMonitor()

        monitor.touched()
        #expect(recorder.states.isEmpty, "rested before its time")
        recorder.passTime()
        #expect(recorder.states == [true])
        #expect(monitor.isResting)

        monitor.touched()
        #expect(recorder.states == [true, false], "a touch did not wake it")
        #expect(!monitor.isResting)
        // And the clock runs again from that touch.
        recorder.passTime()
        #expect(recorder.states == [true, false, true])
    }

    /// A deadline set before the latest touch does nothing: someone who
    /// keeps touching never sees decoration rest, and a touch while awake
    /// says nothing at all.
    @Test func aLaterTouchCancelsTheEarlierDeadlines() {
        let (monitor, recorder) = makeMonitor()
        monitor.touched()
        monitor.touched()
        let stale = recorder.deadlines
        monitor.touched()

        stale.forEach { $0() }

        #expect(recorder.states.isEmpty, "an old deadline rested the app: \(recorder.states)")
        #expect(!monitor.isResting)
        // The latest one still counts.
        recorder.passTime()
        #expect(recorder.states == [true])
    }

    /// The deadline is the configured rest delay.
    @Test func theDeadlineIsTheRestDelay() {
        let monitor = IdleCalmMonitor()
        var asked: [TimeInterval] = []
        monitor.apply = { _ in }
        monitor.schedule = { delay, _ in asked.append(delay) }

        monitor.touched()

        #expect(asked == [IdleCalm.after])
        #expect(IdleCalm.after == 30)
    }

    /// A watcher that saw a touch fails at once, and never blocks or delays
    /// what the content's own gestures do with it.
    @Test func theTouchWatcherClaimsNothing() {
        let watcher = IdleTouchWatcher {}
        let other = UIPanGestureRecognizer()

        #expect(!watcher.cancelsTouchesInView)
        #expect(!watcher.delaysTouchesBegan)
        #expect(!watcher.delaysTouchesEnded)
        #expect(!watcher.canPrevent(other))
        #expect(!watcher.canBePrevented(by: other))
    }

    /// The badge's breath stops when the app rests and comes back when it
    /// wakes, without the badge being touched or laid out again.
    @Test func theWalletBadgeRestsAndWakesWithTheApp() {
        let badge = WalletBadgeButton()
        var resting = false
        badge.reducesMotion = { resting }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        window.addSubview(badge)
        badge.update(balance: 120, claimAvailable: true)
        #expect(badge.isBreathing, "guard: a claim waiting breathes")

        resting = true
        NotificationCenter.default.post(name: .decorativeMotionDidChange, object: nil)
        #expect(!badge.isBreathing, "the badge breathed on at rest")
        #expect(badge.isGlowing, "the glow is what stays")

        resting = false
        NotificationCenter.default.post(name: .decorativeMotionDidChange, object: nil)
        #expect(badge.isBreathing, "waking left the badge still")
        _ = window
    }

    /// ⚠️ THE BONES REST WITH THE APP (#789): an endless window-sized sweep on
    /// a load that never answers recomposited the whole frame forever — and a
    /// still bone shows no band at all, never a frozen one mid-screen.
    @Test func aSkeletonsSweepRestsAndWakesWithTheApp() {
        let bone = SkeletonBoneView()
        var still = false
        bone.stillsMotion = { still }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        window.addSubview(bone)
        bone.frame = CGRect(x: 0, y: 0, width: 120, height: 12)
        #expect(bone.isSweeping, "guard: a bone on screen sweeps")
        #expect(bone.showsBand)

        still = true
        NotificationCenter.default.post(name: .decorativeMotionDidChange, object: nil)
        #expect(!bone.isSweeping, "the bone swept on at rest")
        #expect(!bone.showsBand, "a frozen band was left mid-screen")

        still = false
        NotificationCenter.default.post(name: .decorativeMotionDidChange, object: nil)
        #expect(bone.isSweeping, "waking left the bone still")
        #expect(bone.showsBand)
        _ = window
    }
}
