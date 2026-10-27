import Foundation
import Testing
import UIKit
@testable import DesignSystem

/// The screen-level skeleton's timing (#1757): 0.15 s, 0.3 s, 10 s.
@MainActor
struct SkeletonGateTests {
    @MainActor
    final class ManualClock {
        var now: TimeInterval = 0
        private var pending: [(at: TimeInterval, work: @MainActor () -> Void)] = []
        var clock: SkeletonGate.Clock {
            SkeletonGate.Clock(now: { [weak self] in self?.now ?? 0 }, after: { [weak self] delay, work in
                guard let self else { return }
                pending.append((now + delay, work))
            })
        }
        func advance(_ seconds: TimeInterval) {
            now += seconds
            while let index = pending.indices.filter({ pending[$0].at <= now }).min(by: { pending[$0].at < pending[$1].at }) {
                pending.remove(at: index).work()
            }
        }
    }

    @Test func noBonesBeforeTheDelay() {
        let time = ManualClock()
        let gate = SkeletonGate(clock: time.clock)
        gate.begin()
        time.advance(0.1)
        #expect(!gate.showsSkeleton)
        time.advance(0.05)
        #expect(gate.showsSkeleton)
    }

    @Test func contentBeforeTheDelayRevealsAtOnceWithNoBones() {
        let time = ManualClock()
        let gate = SkeletonGate(clock: time.clock)
        var revealed = false
        gate.begin()
        time.advance(0.05)
        gate.finish { revealed = true }
        #expect(revealed)
        time.advance(1)
        #expect(!gate.showsSkeleton, "a bone for a load that had landed")
    }

    @Test func shownBonesAreHeldTheirMinimum() {
        let time = ManualClock()
        let gate = SkeletonGate(clock: time.clock)
        var revealed = false
        gate.begin()
        time.advance(0.15)
        #expect(gate.showsSkeleton)
        time.advance(0.05)
        gate.finish { revealed = true }
        #expect(!revealed, "a bone shown for 0.05 s would flash")
        time.advance(0.24)
        #expect(!revealed)
        time.advance(0.02)
        #expect(revealed)
        #expect(!gate.showsSkeleton)
    }

    @Test func aLongWaitIsAnnounced() {
        let time = ManualClock()
        let gate = SkeletonGate(clock: time.clock)
        var announced = 0
        gate.onTakingLonger = { announced += 1 }
        gate.begin()
        time.advance(9.9)
        #expect(announced == 0)
        time.advance(0.2)
        #expect(announced == 1)

        // A load that answered in time announces nothing.
        let quick = SkeletonGate(clock: time.clock)
        var quickAnnounced = 0
        quick.onTakingLonger = { quickAnnounced += 1 }
        quick.begin()
        time.advance(1)
        quick.finish()
        time.advance(20)
        #expect(quickAnnounced == 0)
    }

    /// ⚠️ The sweep's brightest point never matches the page: over the
    /// opaque ground a 55% band peaked at the page's own tone and the bone
    /// read as a transparent hole (#1757).
    @Test func theSweepNeverReachesThePagesTone() {
        let light = UITraitCollection(userInterfaceStyle: .light)
        var base: CGFloat = 0, page: CGFloat = 0, band: CGFloat = 0, alpha: CGFloat = 0
        Surface.skeleton.resolvedColor(with: light).getWhite(&base, alpha: nil)
        Surface.page.resolvedColor(with: light).getWhite(&page, alpha: nil)
        SkeletonBoneView.debugHighlight.resolvedColor(with: light).getWhite(&band, alpha: &alpha)
        let peak = base * (1 - alpha) + band * alpha
        #expect(page - peak > 0.015, "the sweep peaks at \(peak), the page is \(page)")
    }
}
