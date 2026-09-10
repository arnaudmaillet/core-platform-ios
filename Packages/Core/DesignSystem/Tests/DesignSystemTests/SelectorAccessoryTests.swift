import Testing
import UIKit
@testable import DesignSystem

/// The two rules that let a `PagedTabBar` be a control at BOTH widths UIKit
/// hands an accessory, and the one that stops a second host taking down the
/// first one's band.
@MainActor
struct SelectorAccessoryTests {

    private func makeHost() -> (SelectorAccessoryHost, PagedTabBar) {
        let strip = PagedTabBar(titles: ["One", "Two", "Three"], style: .navigationTitle)
        let host = SelectorAccessoryHost(strip: strip)
        host.frame = CGRect(x: 0, y: 0, width: 360, height: 48)
        host.layoutIfNeeded()
        return (host, strip)
    }

    /// ⚠️ A HEIGHT IS STATED AND A WIDTH IS NOT. `UITabAccessory` has one
    /// property and no sizing API: the slot is UIKit's to decide (360 regular,
    /// 234 inline, measured), and a content view that argued about the width
    /// would be arguing with the environment. Saying nothing on BOTH axes, which
    /// this once did, is not a neutral answer.
    @Test func theHostStatesAHeightAndNeverAWidth() {
        let (host, _) = makeHost()
        #expect(host.intrinsicContentSize.height == 48)
        #expect(host.intrinsicContentSize.width == UIView.noIntrinsicMetric)
    }

    /// ⚠️ NO WIDTH CONSTRAINT OF ANY KIND. The navigation bar needed a cap
    /// because it sweeps an over-wide group into a `•••`; an accessory has no
    /// item groups and no overflow control, so that failure is unavailable to
    /// it. The one that IS available is the opposite — a width bounded only
    /// from above, with nothing requiring it positive, settling at zero — which
    /// is how the nav-bar host once went unhosted entirely.
    @Test func theStripIsPinnedAndNeverSized() {
        let (host, strip) = makeHost()
        let widthConstraints = (host.constraints + strip.constraints).filter {
            ($0.firstItem === strip || $0.secondItem === strip)
                && ($0.firstAttribute == .width || $0.secondAttribute == .width)
        }
        #expect(widthConstraints.isEmpty, "a width constraint here is how the strip vanishes")
    }

    /// ⚠️ FOUR EQUAL MARGINS, BY CONSTRUCTION. The lens fills its segment when
    /// the backdrop is suppressed, so the strip's inset IS the selection's
    /// margin — pinned flush horizontally it touched the container's left and
    /// right edges while sitting clear of top and bottom.
    @Test func theStripSitsEquallyInsetOnAllFourSides() {
        let (host, strip) = makeHost()
        #expect(strip.frame.minX == 4)
        #expect(strip.frame.minY == 4)
        #expect(host.bounds.maxX - strip.frame.maxX == 4)
        #expect(host.bounds.maxY - strip.frame.maxY == 4)
    }

    /// ⚠️ FILLED IN BOTH ENVIRONMENTS. Hugging is the obvious answer for the
    /// docked state and it is the one that leaves a hole on each side: the
    /// accessory hands out 226pt, three titles want less, and the capsule
    /// centres itself in the difference.
    @Test func theStripSpansTheSlotRatherThanHugging() {
        let (_, strip) = makeHost()
        #expect(strip.fillsWidth)
    }

    /// ⚠️ BARE, OR A LENS INSIDE A LENS. The container draws the capsule the
    /// viewer sees; a strip carrying its own backdrop draws a second one.
    @Test func theStripIsBareUnlessAskedForItsOwnGlass() {
        let (_, strip) = makeHost()
        #expect(strip.suppressesBackdrop)

        let dressed = PagedTabBar(titles: ["One"], style: .navigationTitle)
        _ = SelectorAccessoryHost(strip: dressed, options: .init(keepsOwnGlass: true))
        #expect(!dressed.suppressesBackdrop)
    }

    /// ⚠️ **THE REMOVE IS IDENTITY-CHECKED, AND WITH FOUR HOSTS THAT IS NOT
    /// PEDANTRY.** On a tab switch between two selector screens the outgoing
    /// host's `viewWillDisappear` can land after the incoming host's
    /// `viewDidAppear`; an unchecked remove would then delete the newcomer's
    /// accessory and restore a minimize behaviour captured from elsewhere.
    @Test func removingIsANoOpForSomebodyElsesAccessory() {
        let controller = UITabBarController()
        let mine = SelectorAccessory(strip: PagedTabBar(titles: ["A"], style: .navigationTitle))
        let theirs = SelectorAccessory(strip: PagedTabBar(titles: ["B"], style: .navigationTitle))

        theirs.install(into: controller)
        #expect(controller.bottomAccessory?.contentView === theirs.hostView)

        mine.remove(from: controller)
        #expect(controller.bottomAccessory?.contentView === theirs.hostView,
                "a foreign remove must not take down the accessory in the slot")
    }

    /// ⚠️ THE MINIMIZE IS SHELL-WIDE, SO IT IS OPT-IN. It only means anything
    /// on a host that has registered a scroll view; arming it from one that has
    /// not gives every other tab a collapsing bar and this one nothing.
    @Test func theMinimizeBehaviourIsNotArmedUnlessAsked() {
        let controller = UITabBarController()
        let before = controller.tabBarMinimizeBehavior
        let accessory = SelectorAccessory(strip: PagedTabBar(titles: ["A"], style: .navigationTitle))

        accessory.install(into: controller)
        #expect(controller.tabBarMinimizeBehavior == before)

        accessory.remove(from: controller)
        accessory.install(into: controller, minimizesOnScroll: true)
        #expect(controller.tabBarMinimizeBehavior == .onScrollDown)
    }
}
