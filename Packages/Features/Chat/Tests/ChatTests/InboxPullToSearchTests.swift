import Testing
import UIKit
@testable import Chat

/// **Pull-down-to-search: the line, the release, and everything that must NOT
/// open search.**
///
/// The pull is read off the list's own offset and the release off its own pan,
/// so these drive a bare scroll view's `contentOffset` with the gesture marked
/// as tracking (`debugIsTracking`, the same stand-in the `-messages-pull-demo`
/// hook uses) and let go through `release()` — the method a lifted finger
/// reaches. Off-window, a scroll view's resting offset is 0, so a pull of `d`
/// is an offset of `-d`.
@MainActor
struct InboxPullToSearchTests {
    private func rig() -> (InboxPullToSearch, UIScrollView, Counter) {
        let pull = InboxPullToSearch()
        let list = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        list.contentSize = CGSize(width: 390, height: 2000)
        let counter = Counter()
        pull.onTrigger = { counter.count += 1 }
        pull.attach(to: list)
        return (pull, list, counter)
    }

    private final class Counter { var count = 0 }

    @Test func aPullPastTheLineArmsAndTheReleaseOpensSearch() {
        let (pull, list, opened) = rig()
        pull.debugIsTracking = true

        list.contentOffset.y = -(InboxPullToSearch.threshold + 4)
        #expect(pull.isArmed)

        pull.debugIsTracking = false
        pull.release()
        #expect(opened.count == 1)
        #expect(!pull.isArmed, "the gesture did not stand down after firing")
    }

    @Test func aPullShortOfTheLineOpensNothing() {
        let (pull, list, opened) = rig()
        pull.debugIsTracking = true

        list.contentOffset.y = -(InboxPullToSearch.threshold - 20)
        #expect(!pull.isArmed)

        pull.release()
        #expect(opened.count == 0)
    }

    /// Changing your mind is part of the gesture: back above the line (past
    /// the hysteresis margin) before letting go, and nothing happens.
    @Test func pullingBackAboveTheLineDisarms() {
        let (pull, list, opened) = rig()
        pull.debugIsTracking = true
        list.contentOffset.y = -(InboxPullToSearch.threshold + 10)
        #expect(pull.isArmed)

        list.contentOffset.y = -(InboxPullToSearch.threshold - InboxPullToSearch.disarmMargin - 1)
        #expect(!pull.isArmed)

        pull.release()
        #expect(opened.count == 0)
    }

    /// ⚠️ A finger resting ON the line must not flicker the state: inside the
    /// margin, an armed pull stays armed.
    @Test func aFingerRestingOnTheLineStaysArmed() {
        let (pull, list, _) = rig()
        pull.debugIsTracking = true
        list.contentOffset.y = -InboxPullToSearch.threshold
        #expect(pull.isArmed)

        list.contentOffset.y = -(InboxPullToSearch.threshold - InboxPullToSearch.disarmMargin / 2)
        #expect(pull.isArmed)
    }

    /// Arming follows the FINGER: a list bouncing back through the line after
    /// a release (no tracking) never arms on its way past.
    @Test func aBounceWithoutAFingerNeverArms() {
        let (pull, list, _) = rig()
        pull.debugIsTracking = false

        list.contentOffset.y = -(InboxPullToSearch.threshold + 30)

        #expect(!pull.isArmed)
    }

    /// Disabled — searching already, or mid-page — nothing arms and nothing
    /// opens, and disabling an armed pull stands it down.
    @Test func aDisabledPullNeverOpensSearch() {
        let (pull, list, opened) = rig()
        pull.debugIsTracking = true
        list.contentOffset.y = -(InboxPullToSearch.threshold + 10)
        #expect(pull.isArmed)

        pull.isEnabled = false
        #expect(!pull.isArmed)
        list.contentOffset.y = -(InboxPullToSearch.threshold + 20)
        pull.release()

        #expect(opened.count == 0)
    }

    /// Following a new page's list drops the old one: the old list's offset no
    /// longer arms anything.
    @Test func reattachingFollowsOnlyTheNewList() {
        let (pull, oldList, _) = rig()
        let newList = UIScrollView(frame: oldList.frame)
        newList.contentSize = oldList.contentSize
        pull.attach(to: newList)
        pull.debugIsTracking = true

        oldList.contentOffset.y = -(InboxPullToSearch.threshold + 10)
        #expect(!pull.isArmed, "the previous page's list still drives the gesture")

        newList.contentOffset.y = -(InboxPullToSearch.threshold + 10)
        #expect(pull.isArmed)
    }

    /// The capsule tells the two states apart in words, not only in colour.
    @Test func theCapsuleSaysWhatLettingGoWillDo() {
        let (pull, list, _) = rig()
        pull.debugIsTracking = true
        #expect(pull.indicator.debugLabelText == "Pull to search")

        list.contentOffset.y = -(InboxPullToSearch.threshold + 10)

        #expect(pull.indicator.debugLabelText == "Release to search")
    }
}

/// **The capsule's motion: a meter toward the line, a flood across it, and
/// the same meaning without the motion under Reduce Motion.**
///
/// These read MODEL values — where each animation is heading — since the test
/// host never renders a frame. What they pin is the state each step of the
/// gesture lands in, and that the steps are continuous where they should be
/// (the meter) and reversible where they must be (the flood).
@MainActor
struct PullToSearchIndicatorTests {
    private let threshold = InboxPullToSearch.threshold

    private func indicator(reducingMotion: Bool = false) -> PullToSearchIndicatorView {
        let view = PullToSearchIndicatorView()
        view.reducesMotion = { reducingMotion }
        view.frame = CGRect(origin: .zero, size: view.intrinsicContentSize)
        view.layoutIfNeeded()
        return view
    }

    /// The meter fills continuously with the pull — empty until the capsule
    /// shows, strictly rising through the approach, full exactly at the line,
    /// and never past full.
    @Test func theRingFillsWithThePullAndIsFullAtTheLine() {
        let view = indicator()
        let dead = PullToSearchIndicatorView.deadZone

        view.setPull(distance: dead, threshold: threshold)
        #expect(view.debugRingProgress == 0)

        var previous: CGFloat = 0
        for distance in stride(from: dead + 6, to: threshold, by: 6) {
            view.setPull(distance: distance, threshold: threshold)
            #expect(view.debugRingProgress > previous, "the meter stalled at \(distance)pt")
            #expect(view.debugRingProgress < 1, "the meter was full before the line, at \(distance)pt")
            previous = view.debugRingProgress
        }

        view.setPull(distance: threshold, threshold: threshold)
        #expect(view.debugRingProgress == 1)
        view.setPull(distance: threshold + 40, threshold: threshold)
        #expect(view.debugRingProgress == 1)
    }

    /// Arming floods the capsule from the glyph and widens it for the longer
    /// words; disarming drains the flood and narrows it back — the two are
    /// the same motion, reversed.
    @Test func armingFloodsTheCapsuleAndDisarmingDrainsIt() {
        let view = indicator()
        let restingWidth = view.debugCapsuleWidth
        #expect(view.debugBloomScale < 0.01, "the flood is open before the line")
        #expect(restingWidth == view.debugCapsuleWidth(armed: false))

        view.setArmed(true)
        #expect(view.debugBloomScale == 1)
        #expect(view.debugCapsuleWidth == view.debugCapsuleWidth(armed: true))
        #expect(view.debugCapsuleWidth > restingWidth, "the capsule did not make room for \"Release to search\"")

        view.setArmed(false)
        #expect(view.debugBloomScale < 0.01, "the flood did not drain on disarm")
        #expect(view.debugCapsuleWidth == restingWidth)
    }

    /// The indicator never outgrows its own frame: it is sized for the ARMED
    /// capsule, so arming changes nothing its container lays out.
    @Test func theViewIsSizedForTheArmedCapsule() {
        let view = indicator()
        #expect(view.intrinsicContentSize.width == view.debugCapsuleWidth(armed: true))
        #expect(view.debugCapsuleWidth(armed: true) > view.debugCapsuleWidth(armed: false))
    }

    /// Reduce Motion: no growth on arrival, no flood — the inverted layer
    /// fades in place, and fades back out on disarm.
    @Test func reduceMotionCrossfadesInPlace() {
        let view = indicator(reducingMotion: true)

        view.setPull(distance: threshold * 0.3, threshold: threshold)
        #expect(view.transform.a == 1, "the capsule still grows in under Reduce Motion")

        view.setArmed(true)
        #expect(view.debugBloomScale == 1, "the inverted layer is not simply shown under Reduce Motion")
        #expect(view.debugArmedAlpha == 1)

        view.setArmed(false)
        #expect(view.debugArmedAlpha == 0)
        #expect(view.debugBloomScale == 1, "the flood drained under Reduce Motion instead of fading")
        #expect(view.debugLabelText == PullToSearchIndicatorView.pullTitle)
    }

    /// Without Reduce Motion the capsule grows in with the pull.
    @Test func withMotionTheCapsuleGrowsInWithThePull() {
        let view = indicator()
        view.setPull(distance: threshold * 0.3, threshold: threshold)
        let early = view.transform.a
        view.setPull(distance: threshold, threshold: threshold)
        #expect(early < view.transform.a)
        #expect(view.transform.a == 1)
    }
}
