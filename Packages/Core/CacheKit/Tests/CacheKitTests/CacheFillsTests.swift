import Foundation
import Synchronization
import Testing
import UIKit
@testable import CacheKit

/// A fill that runs until the test lets it finish, counting starts and
/// cancellations. A test AWAITS them (`waitUntilStarted`,
/// `waitUntilCancelled`): the fill runs at utility QoS when asked as P1/P2,
/// and can start long after any budget on a loaded runner (#1057).
private final class FillProbe: Sendable {
    private struct State {
        var started = 0
        var cancelled = 0
        var finished = false
        var priorities: [CacheFillPriority] = []
        var startWaiters = CountWaiters()
        var cancelWaiters = CountWaiters()
    }

    private let state = Mutex(State())
    let value: String

    init(_ value: String) {
        self.value = value
    }

    var started: Int { state.withLock { $0.started } }
    var cancelled: Int { state.withLock { $0.cancelled } }
    var priorityChanges: [CacheFillPriority] { state.withLock { $0.priorities } }

    func finish() { state.withLock { $0.finished = true } }

    /// Returns once the fill has started `count` times.
    func waitUntilStarted(_ count: Int = 1) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let isReached = state.withLock { $0.startWaiters.wait(for: count, count: $0.started, continuation) }
            if isReached { continuation.resume() }
        }
    }

    /// Returns once the fill has been cancelled `count` times.
    func waitUntilCancelled(_ count: Int = 1) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let isReached = state.withLock { $0.cancelWaiters.wait(for: count, count: $0.cancelled, continuation) }
            if isReached { continuation.resume() }
        }
    }

    var fill: CacheFills<String, String>.Fill {
        { [self] context in
            context.onPriorityChange { priority in self.state.withLock { $0.priorities.append(priority) } }
            let starters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
                state.started += 1
                return state.startWaiters.reached(state.started)
            }
            for waiter in starters { waiter.resume() }
            do {
                while !state.withLock({ $0.finished }) {
                    try await Task.sleep(for: .milliseconds(2))
                }
            } catch {
                let cancels = state.withLock { state -> [CheckedContinuation<Void, Never>] in
                    state.cancelled += 1
                    return state.cancelWaiters.reached(state.cancelled)
                }
                for waiter in cancels { waiter.resume() }
                throw error
            }
            return value
        }
    }
}

private final class RequestCounter: Sendable {
    private let count = Atomic<Int>(0)
    var value: Int { count.load(ordering: .acquiring) }
    func increment() { count.add(1, ordering: .releasing) }
}

private final class InterestLog: Sendable {
    private let entries = Mutex<[CacheFillInterest]>([])
    var all: [CacheFillInterest] { entries.withLock { $0 } }
    func append(_ interest: CacheFillInterest) { entries.withLock { $0.append(interest) } }
}

/// Coalesced fills with owner tokens, P0/P1/P2 priorities and the global
/// speculative allowance (#891 scope from #970).
struct CacheFillsTests {
    private let slots = CacheFillSlots(limit: 2)

    private func makeFills() -> CacheFills<String, String> { CacheFills(slots: slots) }

    @Test func twoOwnersShareOneFillAndOnlyTheLastOneCancelsIt() async {
        let fills = makeFills()
        let feed = CacheOwner("vertical-feed")
        let grid = CacheOwner("profile-grid")
        let first = FillProbe("a")
        let second = FillProbe("b")
        fills.request("post-1", priority: .next, owner: feed, fill: first.fill)
        fills.request("post-1", priority: .next, owner: grid, fill: second.fill)
        await first.waitUntilStarted()
        #expect(second.started == 0, "deduplicated by content key")
        #expect(fills.interestCount(for: "post-1") == 2)

        feed.revoke()
        #expect(fills.isInFlight("post-1"), "the grid still wants it")
        #expect(fills.interestCount(for: "post-1") == 1)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(first.cancelled == 0)

        grid.revoke()
        #expect(!fills.isInFlight("post-1"))
        await first.waitUntilCancelled()
        #expect(first.cancelled == 1, "no owner left: cancelled")
    }

    @Test func aFillRunsAtTheHighestPriorityStillWanted() async {
        let fills = makeFills()
        let feed = CacheOwner("feed")
        let grid = CacheOwner("grid")
        let probe = FillProbe("a")
        fills.request("k", priority: .speculative, owner: feed, fill: probe.fill)
        await probe.waitUntilStarted()
        let visible = fills.request("k", priority: .visible, owner: grid, fill: probe.fill)
        #expect(fills.priority(of: "k") == .visible)
        visible.release()
        #expect(fills.priority(of: "k") == .speculative)
        #expect(probe.priorityChanges == [.visible, .speculative], "the fill can follow it (URLSessionTask.priority)")
        feed.revoke()
    }

    @Test func theSameOwnerAskingTwiceUpdatesOneInterest() {
        let fills = makeFills()
        let feed = CacheOwner("feed")
        let probe = FillProbe("a")
        fills.request("k", priority: .speculative, owner: feed, fill: probe.fill)
        fills.request("k", priority: .next, owner: feed, fill: probe.fill)
        #expect(fills.interestCount(for: "k") == 1)
        #expect(feed.interestCount == 1)
        #expect(fills.priority(of: "k") == .next)
        feed.revoke()
    }

    @Test func speculativeFillsShareOneGlobalAllowanceAcrossLists() async {
        let feedFills = makeFills()
        let gridFills = makeFills()
        let feed = CacheOwner("feed")
        let grid = CacheOwner("grid")
        let one = FillProbe("1"), two = FillProbe("2"), three = FillProbe("3")
        feedFills.request("k1", priority: .speculative, owner: feed, fill: one.fill)
        feedFills.request("k2", priority: .speculative, owner: feed, fill: two.fill)
        gridFills.request("k3", priority: .speculative, owner: grid, fill: three.fill)
        #expect(slots.runningCount == 2)
        #expect(slots.waitingCount == 1)
        #expect(!gridFills.isRunning("k3"), "two P2 fills at once, app-wide")

        one.finish()
        // One's end (a utility task) frees its slot: awaited at three's start.
        await three.waitUntilStarted()
        #expect(gridFills.isRunning("k3"), "a freed slot goes to the waiting fill")
        feed.revoke()
        grid.revoke()
        #expect(await eventually { slots.runningCount == 0 && slots.waitingCount == 0 })
    }

    @Test func promotionOutOfP2StartsAQueuedFillAtOnce() async {
        let fills = CacheFills<String, String>(slots: CacheFillSlots(limit: 0))
        let feed = CacheOwner("feed")
        let probe = FillProbe("a")
        let interest = fills.request("k", priority: .speculative, owner: feed, fill: probe.fill)
        #expect(!fills.isRunning("k"))
        interest.setPriority(.visible)
        #expect(fills.isRunning("k"), "on screen: no slot needed")
        await probe.waitUntilStarted()
        feed.revoke()
    }

    @Test(arguments: [CacheFillPriority.next, .visible])
    func p0AndP1NeverWaitForASlot(priority: CacheFillPriority) {
        let fills = CacheFills<String, String>(slots: CacheFillSlots(limit: 0))
        let feed = CacheOwner("feed")
        fills.request("k", priority: priority, owner: feed, fill: FillProbe("a").fill)
        #expect(fills.isRunning("k"))
        feed.revoke()
    }

    @Test func anOwnersCeilingCapsItsInterests() {
        let fills = CacheFills<String, String>(slots: CacheFillSlots(limit: 0))
        let hidden = CacheOwner("hidden-grid")
        hidden.setPriorityCeiling(.speculative)
        fills.request("k", priority: .visible, owner: hidden, fill: FillProbe("a").fill)
        #expect(fills.priority(of: "k") == .speculative, "a hidden list competes as P2 at most")
        #expect(!fills.isRunning("k"))
        hidden.setPriorityCeiling(.visible)
        #expect(fills.priority(of: "k") == .visible)
        #expect(fills.isRunning("k"))
        hidden.revoke()
    }

    @Test func pausedSlotsStartNoNewSpeculativeFill() async {
        let fills = makeFills()
        let feed = CacheOwner("feed")
        slots.setPaused(true)
        fills.request("k", priority: .speculative, owner: feed, fill: FillProbe("a").fill)
        #expect(!fills.isRunning("k"))
        slots.setPaused(false)
        #expect(fills.isRunning("k"))
        feed.revoke()
    }

    @Test func anAwaitingCallerSharesTheInFlightFill() async throws {
        let fills = makeFills()
        let feed = CacheOwner("feed")
        let probe = FillProbe("shared")
        let unused = FillProbe("unused")
        fills.request("k", priority: .speculative, owner: feed, fill: probe.fill)
        await probe.waitUntilStarted()
        let waiter = Task { try await fills.value(for: "k", fill: unused.fill) }
        #expect(await eventually { fills.interestCount(for: "k") == 2 })
        #expect(fills.priority(of: "k") == .visible)
        probe.finish()
        #expect(try await waiter.value == "shared")
        #expect(unused.started == 0)
        #expect(await eventually { feed.interestCount == 0 }, "a finished fill releases its owners")
    }

    @Test func cancellingAnAwaitingCallerDropsOnlyItsOwnInterest() async {
        let fills = makeFills()
        let feed = CacheOwner("feed")
        let probe = FillProbe("a")
        fills.request("k", priority: .next, owner: feed, fill: probe.fill)
        let waiter = Task { try await fills.value(for: "k", fill: probe.fill) }
        #expect(await eventually { fills.interestCount(for: "k") == 2 })
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(fills.isInFlight("k"))
        #expect(fills.interestCount(for: "k") == 1)
        #expect(probe.cancelled == 0)
        feed.revoke()
    }

    @Test func cancellingTheOnlyCallerCancelsTheFill() async {
        let fills = makeFills()
        let probe = FillProbe("a")
        let waiter = Task { try await fills.value(for: "k", fill: probe.fill) }
        await probe.waitUntilStarted()
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        await probe.waitUntilCancelled()
        #expect(probe.cancelled == 1)
        #expect(!fills.isInFlight("k"))
    }

    @Test func aFailedFillThrowsToEveryWaiter() async {
        struct Boom: Error {}
        let fills = makeFills()
        await #expect(throws: Boom.self) {
            try await fills.value(for: "k") { _ in throw Boom() }
        }
        #expect(!fills.isInFlight("k"))
    }

    @Test func aDeallocatedOwnerRevokesItsInterests() {
        let fills = makeFills()
        do {
            let owner = CacheOwner("gone")
            fills.request("k", priority: .next, owner: owner, fill: FillProbe("a").fill)
            #expect(fills.isInFlight("k"))
        }
        #expect(!fills.isInFlight("k"))
    }

    @Test func aRevokedOwnerRegistersNothingAndGetsAnInactiveInterest() {
        let fills = makeFills()
        let feed = CacheOwner("feed")
        let live = fills.request("a", priority: .next, owner: feed, fill: FillProbe("a").fill)
        #expect(live.isActive)
        feed.revoke()
        #expect(feed.isRevoked)
        #expect(!live.isActive)
        let late = fills.request("b", priority: .visible, owner: feed, fill: FillProbe("b").fill)
        #expect(!late.isActive, "detectable by the caller")
        #expect(!fills.isInFlight("b"), "never starts a fill")
        #expect(feed.interestCount == 0)
        late.setPriority(.visible)
        late.release()
        #expect(fills.inFlightCount == 0)
    }

    @Test func oneOwnerHoldsIndependentInterestsInSeveralFills() {
        let images = makeFills()
        let video = makeFills()
        let feed = CacheOwner("feed")
        let poster = images.request("post-1", priority: .next, owner: feed, fill: FillProbe("i").fill)
        let head = video.request("post-1", priority: .next, owner: feed, fill: FillProbe("v").fill)
        #expect(feed.interestCount == 2, "interest ids never collide across fills")
        poster.release()
        #expect(!images.isInFlight("post-1"))
        #expect(video.isInFlight("post-1"))
        #expect(head.isActive)
        feed.revoke()
        #expect(!video.isInFlight("post-1"))
    }

    /// `request` on one thread against `revoke()` on another, many times. The
    /// requesting lane runs until it has SEEN the revoke, so every round has
    /// requests before, during and after it. Once both are done, nothing is
    /// registered, in flight or holding a slot, and every interest is inactive.
    @Test func aRequestRacingARevokeLeavesNothingBehind() {
        let fills = makeFills()
        let longFill: CacheFills<String, String>.Fill = { _ in
            try await Task.sleep(for: .seconds(60))
            return "never"
        }
        let priorities: [CacheFillPriority] = [.speculative, .next, .visible]
        for round in 0..<200 {
            let owner = CacheOwner("race-\(round)")
            let interests = InterestLog()
            let made = RequestCounter()
            DispatchQueue.concurrentPerform(iterations: 2) { lane in
                if lane == 0 {
                    var index = 0
                    var afterRevoke = 0
                    while afterRevoke < 8, index < 100_000 {
                        if owner.isRevoked { afterRevoke += 1 }
                        // Repeated keys exercise the "already wants it" path too.
                        let interest = fills.request("k\(index % 8)", priority: priorities[index % 3], owner: owner, fill: longFill)
                        interests.append(interest)
                        made.increment()
                        index += 1
                    }
                } else {
                    var spins = 0
                    while made.value < round % 12, spins < 10_000_000 { spins += 1 }
                    owner.revoke()
                }
            }
            #expect(owner.interestCount == 0, "round \(round)")
            #expect(fills.inFlightCount == 0, "round \(round)")
            #expect(interests.all.allSatisfy { !$0.isActive }, "round \(round)")
        }
        #expect(slots.runningCount == 0)
        #expect(slots.waitingCount == 0)
    }

    @Test func prioritiesMapToNetworkAndTaskPriorities() {
        #expect(CacheFillPriority.visible.urlSessionTaskPriority == URLSessionTask.highPriority)
        #expect(CacheFillPriority.next.urlSessionTaskPriority == URLSessionTask.defaultPriority)
        #expect(CacheFillPriority.speculative.urlSessionTaskPriority == URLSessionTask.lowPriority)
        #expect(CacheFillPriority.speculative.needsSlot && !CacheFillPriority.next.needsSlot)
    }
}

// MARK: - Escalation of a raised fill (#1052)

/// A one-shot signal a test awaits: nothing here is polled, since a fill
/// that is never raised runs at utility QoS and can start late (#1049).
private final class Signal: Sendable {
    private struct State {
        var isFired = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func fire() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isFired = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let isFired = state.withLock { state -> Bool in
                if !state.isFired { state.waiters.append(continuation) }
                return state.isFired
            }
            if isFired { continuation.resume() }
        }
    }
}

/// A fill that records its task's priority when it starts, then waits for
/// its context to reach `raisedTo` and records it again, then holds until
/// the test lets it finish.
private final class PriorityProbe: Sendable {
    private struct Readings {
        var atStart: TaskPriority?
        var afterRaise: TaskPriority?
    }

    private let readings = Mutex(Readings())
    let started = Signal()
    let raised = Signal()
    let finish = Signal()
    let raisedTo: CacheFillPriority

    init(raisedTo: CacheFillPriority = .visible) {
        self.raisedTo = raisedTo
    }

    var atStart: TaskPriority? { readings.withLock { $0.atStart } }
    var afterRaise: TaskPriority? { readings.withLock { $0.afterRaise } }

    func fill<Value: Sendable>(returning value: Value) -> CacheFills<String, Value>.Fill {
        { [self] context in
            let changes = AsyncStream<CacheFillPriority>.makeStream()
            context.onPriorityChange { changes.continuation.yield($0) }
            readings.withLock { $0.atStart = Task.currentPriority }
            started.fire()
            if context.priority != raisedTo {
                for await priority in changes.stream where priority == raisedTo { break }
            }
            readings.withLock { $0.afterRaise = Task.currentPriority }
            raised.fire()
            await finish.wait()
            return value
        }
    }
}

/// A shared fill runs at the highest priority still wanted: a running
/// prefetch raised to `.visible` has its TASK escalated, not only its
/// context (#1052). Before, it kept decoding at utility QoS while the viewer
/// waited for it.
struct CacheFillEscalationTests {
    @Test func aPrefetchJoinedByAVisibleLoadRunsAtUserInitiatedFromThenOn() async throws {
        let fills = CacheFills<String, String>(slots: CacheFillSlots(limit: 2))
        let owner = CacheOwner("grid")
        let probe = PriorityProbe()
        let interest = fills.request("k", priority: .next, owner: owner, fill: probe.fill(returning: "a"))
        await probe.started.wait()
        #expect(probe.atStart == .utility, "a P1 prefetch starts at utility")

        let visible = Task { try await fills.value(for: "k", priority: .visible) { _ in "unused" } }
        await probe.raised.wait()

        let raised = try #require(probe.afterRaise)
        #expect(raised >= .userInitiated, "joined by a P0 load: user-initiated from then on (\(raised))")
        probe.finish.fire()
        #expect(try await visible.value == "a", "the P0 load rides the prefetch's fill")
        withExtendedLifetime((owner, interest)) {}
    }

    @Test func anInterestRaisedToVisibleEscalatesItsRunningFill() async throws {
        let fills = CacheFills<String, String>(slots: CacheFillSlots(limit: 2))
        let owner = CacheOwner("grid")
        let probe = PriorityProbe()
        let interest = fills.request("k", priority: .speculative, owner: owner, fill: probe.fill(returning: "a"))
        await probe.started.wait()
        #expect(probe.atStart == .utility, "a P2 preload starts at utility")

        interest.setPriority(.visible)
        await probe.raised.wait()

        let raised = try #require(probe.afterRaise)
        #expect(raised >= .userInitiated, "scrolled on screen: user-initiated from then on (\(raised))")
        probe.finish.fire()
        withExtendedLifetime(owner) {}
    }

    @Test func aRaiseThatStaysBelowVisibleLeavesTheFillAtUtility() async throws {
        let slots = CacheFillSlots(limit: 2)
        let fills = CacheFills<String, String>(slots: slots)
        let owner = CacheOwner("grid")
        let probe = PriorityProbe(raisedTo: .next)
        let interest = fills.request("k", priority: .speculative, owner: owner, fill: probe.fill(returning: "a"))
        #expect(slots.runningCount == 1, "P2 still takes a speculative slot")
        await probe.started.wait()

        interest.setPriority(.next)
        await probe.raised.wait()

        #expect(probe.afterRaise == .utility, "P2 to P1 is no reason to escalate")
        probe.finish.fire()
        withExtendedLifetime(owner) {}
    }

    /// An image's decode waits on its download through `value(for:)`: the
    /// download follows the decode, so the bytes the viewer waits for are
    /// fetched at user-initiated too, network hint included.
    @Test func aWaiterFollowingItsParentFillRaisesTheFillItWaitsOn() async throws {
        let slots = CacheFillSlots(limit: 2)
        let decodes = CacheFills<String, String>(slots: slots)
        let downloads = CacheFills<String, Int>(slots: slots)
        let owner = CacheOwner("grid")
        let download = PriorityProbe()
        let interest = decodes.request("photo", priority: .next, owner: owner) { context in
            let bytes = try await downloads.value(for: "photo", priority: .next, following: context, fill: download.fill(returning: 42))
            return "decoded \(bytes)"
        }
        await download.started.wait()
        #expect(downloads.priority(of: "photo") == .next)
        #expect(download.atStart == .utility)

        interest.setPriority(.visible)
        await download.raised.wait()

        #expect(downloads.priority(of: "photo") == .visible, "the download follows its decode")
        let raised = try #require(download.afterRaise)
        #expect(raised >= .userInitiated, "and runs at user-initiated (\(raised))")

        interest.setPriority(.next)
        #expect(downloads.priority(of: "photo") == .next, "lowered with it, never below its own floor")
        download.finish.fire()
        withExtendedLifetime(owner) {}
    }
}

/// The signal sources, driven through a private `NotificationCenter` and
/// injected readers: nothing process-wide is posted or flipped.
struct CacheSignalSourceTests {
    @Test func aNotificationSourceMapsItsOwnCenter() {
        let center = NotificationCenter()
        let recorder = SignalRecorder()
        let name = Notification.Name("CacheKitTests.viewer")
        let source = NotificationCacheSignals(center: center, name, signal: .viewerChanged)
        source.start { recorder.record($0) }
        center.post(name: name, object: nil)
        #expect(recorder.signals == [.viewerChanged])
        source.stop()
        center.post(name: name, object: nil)
        #expect(recorder.signals == [.viewerChanged])
    }

    @Test func theSystemSourceMapsUIKitAndProcessInfoNotifications() {
        let center = NotificationCenter()
        let recorder = SignalRecorder()
        let source = SystemCacheSignals(
            center: center,
            isLowPowerModeEnabled: { true },
            thermalState: { .serious },
            observesMemoryPressure: false,
            observesNetwork: false
        )
        source.start { recorder.record($0) }
        #expect(recorder.signals == [.lowPowerMode(true), .thermalState(.serious)], "the current state first")

        center.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        #expect(Array(recorder.signals.dropFirst(2)) == [
            .memoryWarning, .didEnterBackground, .willEnterForeground, .lowPowerMode(true), .thermalState(.serious)
        ])
        source.stop()
        center.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        #expect(recorder.signals.count == 7)
    }

    @Test func thePolicyFollowsTheConditions() {
        #expect(PrefetchPolicy(conditions: CacheConditions()) == .full)
        #expect(PrefetchPolicy(conditions: CacheConditions(network: .cellular, isNetworkExpensive: true)) == .cellular)
        #expect(PrefetchPolicy(conditions: CacheConditions(isNetworkConstrained: true)) == .reduced)
        #expect(PrefetchPolicy(conditions: CacheConditions(isLowPowerModeEnabled: true)) == .reduced)
        #expect(PrefetchPolicy(conditions: CacheConditions(thermalState: .serious)) == .reduced)
        #expect(PrefetchPolicy(conditions: CacheConditions(thermalState: .critical)) == .off)
        #expect(PrefetchPolicy(conditions: CacheConditions(network: .offline)) == .off)
        #expect(PrefetchPolicy.full.maxConcurrentSpeculativeFills == 2)
        #expect(PrefetchPolicy.reduced.maxConcurrentSpeculativeFills == 0)
    }

    /// Settings → Storage → Use Less Cellular Data (#899): cellular drops to
    /// `reduced` (P2 off, one video ahead); Wi-Fi keeps the full lookahead.
    @Test func useLessCellularDataReducesOnlyCellularPrefetch() {
        #expect(PrefetchPolicy(conditions: CacheConditions(network: .cellular, usesLessCellularData: true)) == .reduced)
        #expect(PrefetchPolicy(conditions: CacheConditions(network: .wifi, isNetworkExpensive: true, usesLessCellularData: true)) == .reduced,
                "a personal hotspot is metered too")
        #expect(PrefetchPolicy(conditions: CacheConditions(network: .wifi, usesLessCellularData: true)) == .full)
        #expect(PrefetchPolicy(conditions: CacheConditions(network: .offline, usesLessCellularData: true)) == .off)
        #expect(PrefetchPolicy.reduced.videoPreloadDepth < PrefetchPolicy.cellular.videoPreloadDepth)
        #expect(PrefetchPolicy.reduced.preloadScreens == 0)
    }
}
