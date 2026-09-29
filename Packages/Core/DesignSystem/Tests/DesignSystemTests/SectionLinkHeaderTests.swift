import Testing
import UIKit
@testable import DesignSystem

/// `Title … [3] ›`: the section header that is a way in, and the tab bar's
/// collapse claimed by a screen with no selector band.
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

    /// The whole bar is the control — a target, and a button to VoiceOver.
    @Test func theWholeBarIsAButton() {
        let header = SectionLinkHeaderView(title: "Friends")
        #expect(header.isAccessibilityElement)
        #expect(header.accessibilityTraits.contains(.button))
        header.frame = CGRect(x: 0, y: 0, width: 360, height: SectionLinkHeaderView.height)
        header.layoutIfNeeded()
        #expect(header.hitTest(CGPoint(x: 180, y: 22), with: nil) === header)
    }

    /// A claim with no band still counts in the shared store: it arms the
    /// collapse, and giving it back restores what the shell had.
    @Test func aBandlessClaimArmsAndRestoresTheCollapse() {
        let controller = UITabBarController()
        controller.tabBarMinimizeBehavior = .never
        let claim = TabBarMinimizeClaim()
        claim.arm(controller)
        claim.arm(controller)
        #expect(claim.isArmed)
        #expect(controller.tabBarMinimizeBehavior == .onScrollDown)
        claim.release()
        claim.release()
        #expect(!claim.isArmed)
        #expect(controller.tabBarMinimizeBehavior == .never)
    }
}
