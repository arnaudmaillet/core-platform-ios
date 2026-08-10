import Testing
@testable import Profile

/// TWO GESTURES WANT THE SAME DRAG.
///
/// A pushed profile can page between its tabs and can go back, and both are a
/// horizontal swipe. The rule that settles it is what the drag could otherwise
/// do: on the FIRST tab there is nothing to the left, so a rightward drag would
/// only rubber-band and the whole surface may dismiss. Past the first tab the
/// same drag pages, and dismissing belongs to the screen edge alone.
///
/// One boolean, invisible at both call sites, deciding which gesture a thumb
/// reaches — which is exactly the kind of rule that drifts silently.
struct ProfileDismissalPolicyTests {
    @Test func theFirstTabGivesTheWholeSurfaceToTheDismissal() {
        #expect(ProfileDismissalPolicy.allowsFullWidthDismissal(activeIndex: 0, isPushed: true))
    }

    /// The case the gate exists for: a mid-surface drag on a later tab must
    /// page, not pop. If this ever returns true, the pager becomes unreachable
    /// by thumb on every tab but the first.
    @Test func laterTabsKeepTheirDragForPaging() {
        for index in 1...4 {
            #expect(
                ProfileDismissalPolicy.allowsFullWidthDismissal(
                    activeIndex: index, isPushed: true
                ) == false,
                "tab \(index) handed its paging drag to the dismissal"
            )
        }
    }

    /// …and the edge never stops dismissing, whichever tab is showing. The
    /// full-width rule is "and also the surface", never "instead of the edge".
    @Test func theEdgeDismissesFromEveryTab() {
        #expect(ProfileDismissalPolicy.allowsEdgeDismissal(isPushed: true))
    }

    /// A profile that IS the tab root has nothing to go back to. A full-width
    /// pop gesture there would either do nothing or tear the root off its own
    /// stack — so the first-tab rule must not fire for it.
    @Test func aRootProfileNeverDismisses() {
        #expect(
            ProfileDismissalPolicy.allowsFullWidthDismissal(activeIndex: 0, isPushed: false) == false
        )
        #expect(ProfileDismissalPolicy.allowsEdgeDismissal(isPushed: false) == false)
    }
}
