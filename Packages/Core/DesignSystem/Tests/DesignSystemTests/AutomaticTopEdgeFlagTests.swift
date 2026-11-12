import Testing
import UIKit
@testable import DesignSystem

/// `-top-edge-automatic` (#2327): the titled contract's style goes from
/// `.soft` to UIKit's `.automatic`, and nothing else changes — the edge is
/// still shown, the clearance still installed, a pager still forwards it.
///
/// Each test states the flag through `SoftTopEdge.automaticStyleOverride`
/// and puts it back before returning; the tests are synchronous on the main
/// actor, so no other suite reads the style while it is stated.
@MainActor
struct AutomaticTopEdgeFlagTests {
    private func withFlag(_ on: Bool, _ body: () -> Void) {
        SoftTopEdge.automaticStyleOverride = on
        defer { SoftTopEdge.automaticStyleOverride = nil }
        body()
    }

    @Test func theFlagIsSwitchableAndAppliesAtLaunch() throws {
        let flag = try #require(DebugFlags.all.first { $0.argument == "-top-edge-automatic" })
        #expect(flag.appliesAtLaunch)
        #expect(flag.title == "Automatic top edge")
    }

    @Test func flagOnTheSoftContractWearsTheAutomaticStyleWithItsClearance() {
        withFlag(true) {
            let scrollView = UIScrollView()
            scrollView.prefersClearTopEdge()
            scrollView.prefersSoftTopEdge()
            #expect(!scrollView.topEdgeEffect.isHidden)
            #expect(scrollView.topEdgeEffect.style == .automatic)
            #expect(TopFadeClearanceKeeper.attached(to: scrollView) != nil, "the clearance is kept with the flag on")
        }
    }

    @Test func flagOnATitledHeaderWearsTheAutomaticStyle() {
        withFlag(true) {
            let table = UITableView(frame: .zero, style: .plain)
            table.applyTopEdge(for: .titled)
            #expect(!table.topEdgeEffect.isHidden)
            #expect(table.topEdgeEffect.style == .automatic)
            #expect(TopFadeClearanceKeeper.attached(to: table) != nil)
        }
    }

    @Test func flagOffTheSoftStyleAsBefore() {
        withFlag(false) {
            let scrollView = UIScrollView()
            scrollView.applyTopEdge(for: .titled)
            #expect(!scrollView.topEdgeEffect.isHidden)
            #expect(scrollView.topEdgeEffect.style == .soft)
            #expect(TopFadeClearanceKeeper.attached(to: scrollView) != nil)
        }
    }

    /// The opt-out keeps its meaning: the style changes, no clearance comes.
    @Test func flagOnAnOptOutStillGetsNoClearance() {
        withFlag(true) {
            let scrollView = UIScrollView()
            scrollView.prefersSoftTopEdge(keepsContentBelowFade: false)
            #expect(scrollView.topEdgeEffect.style == .automatic)
            #expect(TopFadeClearanceKeeper.attached(to: scrollView) == nil)
        }
    }

    /// A pager carrying the edge (the profile, Followers) still hands the
    /// clearance to its pages, and only its style follows the flag.
    @Test func flagOnAPagerStillForwardsTheClearance() {
        withFlag(true) {
            let pager = HorizontalPagerView(pages: [UIView(), UIView()])
            pager.pagingScrollView.prefersSoftTopEdge()
            #expect(!pager.pagingScrollView.topEdgeEffect.isHidden)
            #expect(pager.pagingScrollView.topEdgeEffect.style == .automatic)
            #expect((pager.pagingScrollView as? HorizontalPagerScrollView)?.forwardsTopFadeClearance == true)
        }
    }

    /// The untitled rule does not read the flag.
    @Test func flagOnAnUntitledHeaderStaysClear() {
        withFlag(true) {
            let scrollView = UIScrollView()
            scrollView.applyTopEdge(for: .untitled)
            #expect(scrollView.topEdgeEffect.isHidden)
        }
    }
}
