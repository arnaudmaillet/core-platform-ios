import Testing
import UIKit
@testable import DesignSystem

/// WHO OWNS A RIGHTWARD DRAG ON A SCREEN WITH TABS.
///
/// The rule is one boolean and it decides which of two gestures a thumb
/// reaches, so both ways of getting it wrong are silent: too generous and the
/// tabs stop paging, too mean and the screen cannot be left at all.
///
/// The mean version is the one that shipped. A place page asked only "am I on
/// the first tab" and refused everything else — including the leading strip,
/// which the pager beneath it had already given up as the platform's. Both
/// yielded, so on the Activity tab a rightward swipe did nothing from anywhere.
struct PagedScreenDismissalPolicyTests {
    private func allows(x: CGFloat, tab: Int, pushed: Bool = true) -> Bool {
        PagedScreenDismissalPolicy.allowsDismissal(atX: x, activeIndex: tab, isPushed: pushed)
    }

    /// On the FIRST tab there is nothing to the left, so the drag has no other
    /// job and the whole surface may dismiss.
    @Test func theFirstTabDismissesFromAnywhere() {
        #expect(allows(x: 0, tab: 0))
        #expect(allows(x: 200, tab: 0))
        #expect(allows(x: 392, tab: 0))
    }

    /// ⚠️ THE EDGE IS NEVER TRADED AWAY, and this is the case that shipped
    /// broken. Past the first tab the drag pages — except on the strip, which
    /// belongs to the stack on every tab. A screen that refuses it leaves the
    /// band claimed by nobody, because the pager has already yielded it.
    @Test func theEdgeDismissesOnEveryTab() {
        for tab in 1...3 {
            #expect(allows(x: 0, tab: tab), "the very edge on tab \(tab)")
            #expect(allows(x: PagedScreenDismissalPolicy.edgeZone, tab: tab),
                    "the last point of the strip on tab \(tab)")
        }
    }

    /// And past the strip, past the first tab, the drag is the pager's.
    @Test func pastTheStripPastTheFirstTabTheDragPages() {
        #expect(!allows(x: PagedScreenDismissalPolicy.edgeZone + 1, tab: 1))
        #expect(!allows(x: 200, tab: 2))
    }

    /// A screen that IS its stack's root has nothing to go back to, on any tab
    /// and anywhere on the surface. A pop gesture there would either do nothing
    /// or tear the root off its own stack.
    @Test func aRootScreenNeverDismisses() {
        #expect(!allows(x: 0, tab: 0, pushed: false))
        #expect(!allows(x: 200, tab: 0, pushed: false))
        #expect(!allows(x: 0, tab: 2, pushed: false))
    }

    /// The two location-free spellings agree with the located one, so a caller
    /// that has only a tab index cannot reach a different rule.
    @Test func theShorthandsAgreeWithTheLocatedRule() {
        #expect(PagedScreenDismissalPolicy.allowsFullWidthDismissal(activeIndex: 0, isPushed: true)
                    == allows(x: 200, tab: 0))
        #expect(PagedScreenDismissalPolicy.allowsFullWidthDismissal(activeIndex: 1, isPushed: true)
                    == allows(x: 200, tab: 1))
        #expect(PagedScreenDismissalPolicy.allowsEdgeDismissal(isPushed: true)
                    == allows(x: 0, tab: 3))
        #expect(PagedScreenDismissalPolicy.allowsEdgeDismissal(isPushed: false)
                    == allows(x: 0, tab: 3, pushed: false))
    }
}
