import Testing
import UIKit
@testable import MediaCore

/// The loading ladder (#1085): the state machine every loading view shares,
/// and the hooks the zoom hero needs from it.
@MainActor
struct LoadingLadderTests {
    /// A clock a test steps by hand.
    @MainActor
    final class ManualClock {
        var now: TimeInterval = 0
        private var pending: [(at: TimeInterval, work: @MainActor () -> Void)] = []

        var clock: LoadingLadder.Clock {
            // Weak: a ladder can outlive the clock's owner; an unowned read
            // past it would trap the whole test process.
            LoadingLadder.Clock(now: { [weak self] in self?.now ?? 0 }, after: { [weak self] delay, work in
                guard let self else { return }
                pending.append((now + delay, work))
            })
        }

        /// Moves time on, running what fell due, in order.
        func advance(_ seconds: TimeInterval) {
            now += seconds
            while let index = pending.indices.filter({ pending[$0].at <= now }).min(by: { pending[$0].at < pending[$1].at }) {
                let due = pending.remove(at: index)
                due.work()
            }
        }
    }

    @MainActor
    private struct Rig {
        let ladder: LoadingLadder
        let clock: ManualClock
        let skeleton = UIView()
        let placeholder = UIView()
        let preview = UIImageView()
        let content = UIImageView()
    }

    private func makeRig(policy: LoadingLadder.Policy = .standard) -> Rig {
        let clock = ManualClock()
        let rig = Rig(ladder: LoadingLadder(policy: policy, clock: clock.clock), clock: clock)
        rig.ladder.setView(rig.skeleton, for: .skeleton)
        rig.ladder.setView(rig.placeholder, for: .placeholder)
        rig.ladder.setView(rig.preview, for: .preview)
        rig.ladder.setView(rig.content, for: .content)
        return rig
    }

    // MARK: - The state machine

    /// A warm hit draws in the configure pass: no skeleton, no transition.
    @Test func aWarmHitDrawsInTheSamePass() {
        let rig = makeRig()
        let token = rig.ladder.begin(item: "a")
        rig.ladder.show(.content, token: token, warm: true)
        #expect(rig.ladder.rung == .content)
        #expect(!rig.content.isHidden && rig.content.alpha == 1)
        #expect(rig.ladder.transitions.last?.1 == LoadingLadder.Transition.none)
        rig.clock.advance(1)
        #expect(rig.skeleton.isHidden, "a skeleton for content already there")
        #expect(rig.ladder.isSettled)
    }

    /// A late arrival animates with its rung's transition.
    @Test func aLateArrivalDissolves() {
        let rig = makeRig()
        let token = rig.ladder.begin(item: "a")
        rig.ladder.show(.content, token: token)
        #expect(rig.ladder.transitions.last?.1 == .pictureArrives)
    }

    /// ⚠️ A LATE ANSWER FOR A REUSED VIEW LANDS NOWHERE: the generation moved
    /// on with the new item.
    @Test func aLateAnswerAfterReuseLandsNowhere() {
        let rig = makeRig()
        let old = rig.ladder.begin(item: "a")
        _ = rig.ladder.begin(item: "b")
        rig.ladder.show(.content, token: old)
        #expect(rig.ladder.rung != .content)
        #expect(rig.content.isHidden)
        #expect(!rig.ladder.isCurrent(old))
    }

    /// A reused view never keeps the previous item's layers: a new item cuts.
    @Test func aNewItemCuts() {
        let rig = makeRig()
        let first = rig.ladder.begin(item: "a")
        rig.ladder.show(.content, token: first, warm: true)
        _ = rig.ladder.begin(item: "b")
        #expect(rig.content.isHidden)
        #expect(rig.ladder.rung == nil)
        #expect(!rig.ladder.isSettled)
    }

    /// A failure keeps the highest rung reached and settles.
    @Test func aFailureFallsBackToTheHighestRungReached() {
        let rig = makeRig()
        let token = rig.ladder.begin(item: "a")
        rig.ladder.show(.preview, token: token, warm: true)
        var settled = 0
        rig.ladder.onSettled = { settled += 1 }
        rig.ladder.fail(token: token)
        #expect(rig.ladder.rung == .preview)
        #expect(!rig.preview.isHidden)
        #expect(rig.ladder.isSettled)
        #expect(settled == 1)
    }

    /// ⚠️ A failure inside the skeleton's delay: no bone afterwards — nothing
    /// is coming, and a bone landing late stayed for good (#1752).
    @Test func aFailureBeforeTheDelayLeavesNoBone() {
        let rig = makeRig()
        let token = rig.ladder.begin(item: "a")
        rig.ladder.fail(token: token)
        rig.clock.advance(1)
        #expect(rig.skeleton.isHidden)
        #expect(rig.ladder.rung != .skeleton)
    }

    // MARK: - The skeleton's timing

    /// A skeleton shows only after the delay, never for a load that lands
    /// before it.
    @Test func theSkeletonShowsOnlyAfterTheDelay() {
        let rig = makeRig()
        _ = rig.ladder.begin(item: "a")
        rig.clock.advance(LoadingLadder.Policy.standard.skeletonDelay - 0.01)
        #expect(rig.skeleton.isHidden)
        rig.clock.advance(0.02)
        #expect(!rig.skeleton.isHidden)
        #expect(rig.ladder.rung == .skeleton)
    }

    /// Once shown, a skeleton stays its minimum: content arriving just after
    /// waits for it, then lands.
    @Test func aShownSkeletonStaysItsMinimum() {
        let rig = makeRig()
        let token = rig.ladder.begin(item: "a")
        rig.clock.advance(LoadingLadder.Policy.standard.skeletonDelay + 0.01)
        rig.ladder.show(.content, token: token)
        #expect(rig.ladder.rung == .skeleton, "the bone would flash for a frame")
        rig.clock.advance(LoadingLadder.Policy.standard.skeletonMinimum)
        #expect(rig.ladder.rung == .content)
    }

    // MARK: - The hero's hooks

    /// Held by a flight: nothing transitions; what arrived lands at the
    /// release, without animation (hook 3).
    @Test func aHeldViewLandsALateArrivalAtTheReleaseWithoutAnimation() {
        let rig = makeRig()
        let token = rig.ladder.begin(item: "a")
        rig.ladder.hold()
        rig.ladder.show(.content, token: token)
        #expect(rig.ladder.rung != .content, "nothing moves while held")
        rig.ladder.release()
        #expect(rig.ladder.rung == .content)
        #expect(rig.ladder.transitions.last?.1 == LoadingLadder.Transition.none)
        #expect(!rig.content.isHidden && rig.content.alpha == 1)
    }

    /// Lent content (hook 4): the ladder neither touches the view nor steps
    /// back while it is away.
    @Test func lentContentIsNeverSteppedBackOrTouched() {
        let rig = makeRig()
        let token = rig.ladder.begin(item: "a")
        rig.ladder.show(.content, token: token, warm: true)
        rig.ladder.lendContent()
        rig.content.alpha = 0.5 // the borrower's business
        rig.ladder.show(.preview, token: token, warm: true)
        _ = rig.ladder.begin(item: "a") // a reconfigure meanwhile
        #expect(rig.ladder.rung == .content)
        #expect(rig.content.alpha == 0.5)
        rig.ladder.reclaimContent()
        #expect(rig.content.alpha == 1)
    }

    /// A readiness drop never steps back (hook 5), nor does a lower rung
    /// arriving after a higher one.
    @Test func aReadinessDropNeverStepsBack() {
        let rig = makeRig()
        let token = rig.ladder.begin(item: "a")
        rig.ladder.show(.content, token: token, warm: true)
        rig.ladder.contentDropped()
        rig.ladder.show(.preview, token: token)
        #expect(rig.ladder.rung == .content)
        #expect(rig.preview.isHidden)
    }

    /// A flight card draws its source's state at once (hook 6).
    @Test func aFlightCardDrawsAtOnce() {
        let rig = makeRig()
        rig.ladder.isFlightCard = true
        let token = rig.ladder.begin(item: "a")
        rig.clock.advance(1)
        #expect(rig.skeleton.isHidden, "no skeleton delay on a card")
        rig.ladder.show(.content, token: token)
        #expect(rig.ladder.transitions.last?.1 == LoadingLadder.Transition.none)
    }

    /// A parked frame outranks the pipeline's thumbnail landing later (hook 7).
    @Test func aParkedFrameOutranksTheThumbnail() {
        let rig = makeRig()
        let token = rig.ladder.begin(item: "a")
        let parked = UIImage()
        rig.preview.image = parked
        rig.ladder.show(.preview, token: token, warm: true, source: .parked)
        rig.ladder.show(.preview, token: token, source: .pipeline)
        #expect(rig.ladder.previewSource == .parked)
        #expect(rig.ladder.transitions.count == 1, "the thumbnail did not land over the parked frame")
    }

    /// Reconfigure is not reuse (hook 8): the same item keeps its generation
    /// and its layers.
    @Test func aReconfigureKeepsTheGeneration() {
        let rig = makeRig()
        let token = rig.ladder.begin(item: "a")
        rig.ladder.show(.content, token: token, warm: true)
        let again = rig.ladder.begin(item: "a")
        #expect(again == token)
        #expect(rig.ladder.rung == .content)
        #expect(!rig.content.isHidden)
    }

    /// One driver per alpha (hook 2): a live surface's alpha is its own.
    @Test func aLiveSurfaceAlphaIsNeverWritten() {
        let clock = ManualClock()
        let ladder = LoadingLadder(clock: clock.clock)
        let live = UIView()
        live.alpha = 0
        ladder.setView(live, for: .content, drivesAlpha: false)
        let token = ladder.begin(item: "a")
        ladder.show(.content, token: token)
        #expect(ladder.transitions.last?.1 == .firstFrame)
        #expect(live.alpha == 0, "the surface reveals itself on its first frame")
        #expect(!live.isHidden)
    }

    /// A permanent floor (an avatar's initials) stays under what covers it.
    @Test func aPermanentFloorStaysUnderTheContent() {
        let clock = ManualClock()
        let ladder = LoadingLadder(clock: clock.clock)
        let initials = UIView()
        let picture = UIImageView()
        ladder.setView(initials, for: .placeholder, permanent: true)
        ladder.setView(picture, for: .content)
        let token = ladder.begin(item: "a")
        ladder.show(.placeholder, token: token, warm: true)
        ladder.show(.content, token: token, warm: true)
        #expect(!initials.isHidden)
        #expect(!picture.isHidden)
    }

    /// The fade law (hook 9): the arriving rung moves, the one below stays
    /// opaque until it has landed.
    @Test func theArrivingRungFadesOverAnOpaqueFloor() {
        let rig = makeRig()
        let token = rig.ladder.begin(item: "a")
        rig.ladder.show(.preview, token: token, warm: true)
        rig.ladder.show(.content, token: token)
        #expect(rig.preview.alpha == 1 && !rig.preview.isHidden, "the floor stays while the picture fades in")
        #expect(!rig.content.isHidden)
    }
}
