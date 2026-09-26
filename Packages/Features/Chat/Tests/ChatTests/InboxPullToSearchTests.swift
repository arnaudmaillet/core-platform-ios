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
