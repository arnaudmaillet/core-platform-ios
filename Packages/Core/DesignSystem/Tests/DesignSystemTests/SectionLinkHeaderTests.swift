import Testing
import UIKit
@testable import DesignSystem

/// `Title … [3] ›`: the section header that is a way in — and the plain
/// heading it becomes when it is not one.
@MainActor
struct SectionLinkHeaderTests {
    @Test func nothingNewDrawsNoPill() {
        let header = SectionLinkHeaderView(title: "Friends")
        #expect(header.debugCountText == nil)
        header.setCount(0)
        #expect(header.debugCountText == nil)
        #expect(header.accessibilityValue == nil)
    }

    @Test func aCountIsTheNumberUntilItStopsBeingRead() {
        let header = SectionLinkHeaderView(title: "Following")
        header.setCount(3)
        #expect(header.debugCountText == "3")
        #expect(header.accessibilityLabel == "Following")
        #expect(header.accessibilityValue == "3 new")
        header.setCount(250)
        #expect(header.debugCountText == "99+")
        header.setCount(-2)
        #expect(header.debugCountText == nil, "a negative count is not an indicator")
    }

    /// The whole bar is the target, a button to VoiceOver — and a TAP
    /// recogniser answers it. #312 shipped the bar as a plain `UIControl`
    /// listening for `.primaryActionTriggered`, which a plain control never
    /// sends: the chevron did nothing on device.
    @Test func theWholeBarIsATapTarget() {
        let header = SectionLinkHeaderView(title: "Friends")
        #expect(header.isAccessibilityElement)
        #expect(header.accessibilityTraits.contains(.button))
        header.frame = CGRect(x: 0, y: 0, width: 360, height: SectionLinkHeaderView.height)
        header.layoutIfNeeded()
        #expect(header.hitTest(CGPoint(x: 180, y: 22), with: nil) === header)
        #expect(header.gestureRecognizers?.contains { $0 is UITapGestureRecognizer } == true)
        #expect(header.debugShowsChevron)

        var taps = 0
        header.onTap = { taps += 1 }
        header.debugTap()
        #expect(taps == 1)
        #expect(header.accessibilityActivate())
        #expect(taps == 2)
    }

    /// "For you" over the list: a heading, not a way in — no chevron, nothing
    /// to tap, and its touches left to the list under it.
    @Test func aHeadingThatIsNotALinkTakesNoTouch() {
        let header = SectionLinkHeaderView(title: "For you", isLink: false)
        header.frame = CGRect(x: 0, y: 0, width: 360, height: SectionLinkHeaderView.height)
        header.layoutIfNeeded()
        #expect(!header.debugShowsChevron)
        #expect(header.accessibilityTraits.contains(.header))
        #expect(!header.accessibilityTraits.contains(.button))
        #expect(header.hitTest(CGPoint(x: 180, y: 22), with: nil) == nil)
        var taps = 0
        header.onTap = { taps += 1 }
        #expect(!header.accessibilityActivate())
        #expect(taps == 0)
    }
}
