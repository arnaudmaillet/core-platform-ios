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

    /// `Friends (3) ›` reads as one phrase (2026-09-30): the pill and the
    /// chevron follow the title, left-aligned, and the rest of the bar is empty
    /// — but still tappable, since the whole bar is the target.
    @Test func theCountAndChevronFollowTheTitle() {
        let header = SectionLinkHeaderView(title: "Friends")
        header.setCount(3)
        header.frame = CGRect(x: 0, y: 0, width: 360, height: SectionLinkHeaderView.height)
        header.layoutIfNeeded()
        let frames = header.debugFrames
        #expect(frames.title.minX == 0)
        #expect(frames.badge.minX > frames.title.maxX)
        #expect(frames.badge.minX - frames.title.maxX <= 12, "right after the title, not at the edge")
        #expect(frames.chevron.minX > frames.badge.maxX)
        #expect(frames.chevron.maxX < 180, "the run stops well short of the trailing edge")
        #expect(header.hitTest(CGPoint(x: 340, y: 22), with: nil) === header, "the empty end still opens")

        // Nothing new: the chevron sits beside the title, no pill's place kept.
        let quiet = SectionLinkHeaderView(title: "Friends")
        quiet.frame = header.frame
        quiet.layoutIfNeeded()
        let bare = quiet.debugFrames
        #expect(bare.badge.isNull)
        #expect(bare.chevron.minX - bare.title.maxX <= 12, "title \(bare.title) chevron \(bare.chevron)")
    }

    /// A count going to zero ON SCREEN (Following read) gives the pill's place
    /// back — the chevron closes up on the title.
    @Test func aCountGoingToZeroClosesTheGap() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 360, height: 200))
        window.isHidden = false
        defer { window.isHidden = true }
        let header = SectionLinkHeaderView(title: "Following")
        header.frame = CGRect(x: 0, y: 0, width: 360, height: SectionLinkHeaderView.height)
        window.addSubview(header)
        header.setCount(3)
        header.layoutIfNeeded()
        header.setCount(0)
        header.layoutIfNeeded()
        let bare = header.debugFrames
        #expect(bare.badge.isNull)
        #expect(bare.chevron.minX - bare.title.maxX <= 12, "title \(bare.title) chevron \(bare.chevron)")
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
