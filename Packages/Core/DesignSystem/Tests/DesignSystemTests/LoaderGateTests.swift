import Foundation
import Testing
import UIKit
@testable import DesignSystem

/// The loader's timing (#1768): nothing for the grace, the loader once it
/// runs out — if the wait is still on — held at least the minimum.
@MainActor
struct LoaderGateTests {
    private typealias ManualClock = SkeletonGateTests.ManualClock

    private final class Switches {
        var log: [Bool] = []
    }

    private func gate(_ time: ManualClock, _ switches: Switches) -> LoaderGate {
        LoaderGate(clock: time.clock) { switches.log.append($0) }
    }

    @Test func oneTimingForEveryLoadingState() {
        #expect(LoadingTiming.skeletonDelay == 0.15)
        #expect(LoadingTiming.loaderGrace == 0.25)
        #expect(LoadingTiming.minimum == 0.3)
        #expect(LoadingTiming.takingLonger == 10)
        #expect(SkeletonGate.Timing.standard.delay == LoadingTiming.skeletonDelay)
        #expect(SkeletonGate.Timing.standard.minimum == LoadingTiming.minimum)
        #expect(SkeletonGate.Timing.standard.takingLonger == LoadingTiming.takingLonger)
    }

    @Test func noLoaderBeforeTheGrace() {
        let time = ManualClock()
        let switches = Switches()
        let gate = gate(time, switches)
        gate.begin()
        time.advance(LoadingTiming.loaderGrace - 0.01)
        #expect(switches.log.isEmpty)
        #expect(gate.isArmed)
        time.advance(0.01)
        #expect(switches.log == [true])
        #expect(gate.isShowing && !gate.isArmed)
    }

    @Test func aWaitOverDuringTheGraceShowsNothing() {
        let time = ManualClock()
        let switches = Switches()
        let gate = gate(time, switches)
        var done = false
        gate.begin()
        gate.end { done = true }
        time.advance(1)
        #expect(switches.log.isEmpty)
        #expect(done)
    }

    @Test func theGraceAsksAgain() {
        let time = ManualClock()
        let switches = Switches()
        let gate = gate(time, switches)
        var waiting = true
        gate.begin { waiting }
        waiting = false
        time.advance(1)
        #expect(switches.log.isEmpty, "a loader for a wait that ended in the grace")
    }

    @Test func aShownLoaderStaysItsMinimum() {
        let time = ManualClock()
        let switches = Switches()
        let gate = gate(time, switches)
        var done = false
        gate.begin()
        time.advance(LoadingTiming.loaderGrace)
        gate.end { done = true }
        gate.end()
        #expect(switches.log == [true])
        time.advance(LoadingTiming.minimum - 0.01)
        #expect(switches.log == [true] && !done)
        time.advance(0.01)
        #expect(switches.log == [true, false])
        #expect(done && !gate.isShowing)
    }

    @Test func aWaitBackInTheMinimumKeepsTheLoader() {
        let time = ManualClock()
        let switches = Switches()
        let gate = gate(time, switches)
        gate.begin()
        time.advance(LoadingTiming.loaderGrace)
        gate.end()
        gate.begin()
        time.advance(1)
        #expect(switches.log == [true])
        #expect(gate.isShowing)
        // Its minimum already had: down at once.
        gate.end()
        #expect(switches.log == [true, false])
    }

    @Test func cancelDropsItNow() {
        let time = ManualClock()
        let switches = Switches()
        let gate = gate(time, switches)
        gate.begin()
        time.advance(LoadingTiming.loaderGrace)
        gate.cancel()
        #expect(switches.log == [true, false])
        gate.begin()
        gate.cancel()
        time.advance(1)
        #expect(switches.log == [true, false, false])
    }

    @Test func itDrivesAnAppLoader() {
        let time = ManualClock()
        let loader = AppLoaderView(size: .medium)
        loader.hidesWhenStopped = true
        let gate = LoaderGate(loader: loader, clock: time.clock)
        gate.begin()
        #expect(!loader.isAnimating)
        time.advance(LoadingTiming.loaderGrace)
        #expect(loader.isAnimating)
        gate.cancel()
        #expect(!loader.isAnimating)
    }

    #if DEBUG
    @Test func theGraceCanBeRunOut() {
        let time = ManualClock()
        let switches = Switches()
        let gate = gate(time, switches)
        gate.begin()
        gate.debugElapseGrace()
        #expect(switches.log == [true])
        time.advance(1)
        #expect(switches.log == [true], "the grace ran twice")
    }
    #endif
}
