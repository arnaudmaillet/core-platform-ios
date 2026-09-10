import Testing
import UIKit
@testable import DesignSystem

/// The two rules that let a `PagedTabBar` be a control at BOTH widths UIKit
/// hands an accessory, and the one that stops a second host taking down the
/// first one's band.
@MainActor
struct SelectorAccessoryTests {

    private func makeHost(
        titles: [String] = ["One", "Two", "Three"],
        environment: UITabAccessory.Environment? = nil,
        width: CGFloat = 360
    ) -> (SelectorAccessoryHost, PagedTabBar) {
        let strip = PagedTabBar(titles: titles, style: .navigationTitle)
        let host = SelectorAccessoryHost(strip: strip)
        // ⚠️ THE ENVIRONMENT IS DRIVABLE WITHOUT A `UITabBarController`.
        // `UITraitOverrides` conforms to `UIMutableTraits`, which carries a
        // settable `tabAccessoryEnvironment` — so the collapsed arrangement is
        // a unit test rather than a UITest with a real finger.
        if let environment {
            host.traitOverrides.tabAccessoryEnvironment = environment
            host.updateTraitsIfNeeded()
        }
        host.frame = CGRect(x: 0, y: 0, width: width, height: 48)
        host.layoutIfNeeded()
        return (host, strip)
    }

    /// Each segment's laid-out width, largest-minus-smallest — the number that
    /// says which arrangement is running.
    private func widthSpread(_ strip: PagedTabBar) -> CGFloat {
        let widths = strip.debugSegmentWidths
        guard let low = widths.min(), let high = widths.max() else { return 0 }
        return high - low
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

    /// ⚠️ **THE BAR ALWAYS SPANS; ONLY THE SEGMENTS CHANGE.** `fillsWidth` says
    /// "the host owns my width", which is true in both environments — the
    /// accessory's slot is UIKit's and it does not negotiate (measured: a
    /// REQUIRED width constraint on the content view is inert, no conflict
    /// logged). What the collapse changes is how the segments divide that slot.
    @Test func theStripTakesItsWidthFromTheHostInEveryEnvironment() {
        #expect(makeHost().1.fillsWidth)
        #expect(makeHost(environment: .regular).1.fillsWidth)
        #expect(makeHost(environment: .inline, width: 234).1.fillsWidth)
    }

    /// ⚠️ **THIS TEST USED TO PASS FOR THE WRONG REASON.** It was named "spans
    /// rather than hugs" and asserted one Bool on a DETACHED host — whose
    /// environment is `.unspecified` — so it would have gone on passing after
    /// the collapsed arrangement changed underneath it. What it should have
    /// been measuring is the segments.
    @Test func expandedSegmentsShareTheSlotEqually() {
        let (_, strip) = makeHost(titles: ["All", "Requests", "Suggestions"],
                                  environment: .regular)
        #expect(strip.segmentSizing == .equalSlots)
        #expect(widthSpread(strip) < 0.5,
                "expanded, every segment is as wide as the widest: \(strip.debugSegmentWidths)")
    }

    /// ⚠️ **AND COLLAPSED THEY ARE NOT.** Equal slots price every segment at
    /// the LONGEST title, so in a 234pt inline slot "All" wears "Suggestions"'
    /// box — 41pt of word in a 98pt box — and the strip scrolls to show three
    /// titles it would otherwise fit. Natural widths are what the inline
    /// environment asks for, and Apple's only sizing sentence about the
    /// accessory says the same thing: "When the accessory is inline with the
    /// tab bar, there is less space available to display it."
    @Test func collapsedSegmentsTakeTheirOwnWidths() {
        let (_, strip) = makeHost(titles: ["All", "Requests", "Suggestions"],
                                  environment: .inline, width: 234)
        #expect(strip.segmentSizing == .naturalWidths)
        #expect(widthSpread(strip) > 0.5,
                "collapsed, a short title gets a short box: \(strip.debugSegmentWidths)")
    }

    /// The collapse is a round trip, and coming back must restore the shape
    /// exactly — not approximately.
    @Test func comingBackFromInlineRestoresTheExpandedShape() {
        let (host, strip) = makeHost(titles: ["All", "Requests", "Suggestions"],
                                     environment: .regular)
        let expanded = strip.debugSegmentWidths
        host.traitOverrides.tabAccessoryEnvironment = .inline
        host.updateTraitsIfNeeded()
        host.frame = CGRect(x: 0, y: 0, width: 234, height: 48)
        host.layoutIfNeeded()
        #expect(strip.segmentSizing == .naturalWidths)

        host.traitOverrides.tabAccessoryEnvironment = .regular
        host.updateTraitsIfNeeded()
        host.frame = CGRect(x: 0, y: 0, width: 360, height: 48)
        host.layoutIfNeeded()
        #expect(strip.segmentSizing == .equalSlots)
        #expect(strip.debugSegmentWidths == expanded)
    }

    /// ⚠️ **`.unspecified` IS THE DEFAULT, AND IT MUST MEAN "LEAVE IT ALONE".**
    /// Every non-accessory host reports it — a navigation bar's title slot, the
    /// stack's bottom toolbar — so a rule written as `!= .regular` would
    /// silently re-arrange all of them.
    @Test func aStripOutsideAnyAccessoryKeepsTheExpandedArrangement() {
        let (_, strip) = makeHost(titles: ["All", "Requests", "Suggestions"])
        #expect(strip.segmentSizing == .equalSlots)
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

    /// ⚠️ **THE HAND-OVER, WHICH IS WHAT MAKES A TAB SWITCH SEAMLESS.** On a
    /// tab switch the incoming screen's `viewWillAppear` lands SIX
    /// MILLISECONDS BEFORE the outgoing screen's `viewWillDisappear`
    /// (measured, headless). So the newcomer claims the slot first and the
    /// screen it replaced must find the band is no longer its own and leave it
    /// alone — the band is never taken down between two screens that both want
    /// one, and the viewer sees no gap.
    ///
    /// The 900ms this replaced: installed from `viewDidAppear`, the band
    /// arrived +961ms after the tab changed, on a screen that had been fully on
    /// display for most of a second. From `viewWillAppear` it arrives at +20ms.
    @Test func aHandOverLeavesTheNewcomersBandStanding() {
        let controller = UITabBarController()
        let outgoing = SelectorAccessory(strip: PagedTabBar(titles: ["A"], style: .navigationTitle))
        let incoming = SelectorAccessory(strip: PagedTabBar(titles: ["B"], style: .navigationTitle))

        outgoing.install(into: controller, minimizesOnScroll: true)
        // The order a tab switch actually produces: the newcomer first.
        incoming.install(into: controller, minimizesOnScroll: true)
        #expect(controller.bottomAccessory?.contentView === incoming.hostView)

        outgoing.remove(from: controller)
        #expect(controller.bottomAccessory?.contentView === incoming.hostView,
                "the outgoing screen must not take down the band it handed over")
        #expect(controller.tabBarMinimizeBehavior == .onScrollDown,
                "the newcomer still wants the collapse")
    }

    /// ⚠️ **AND THE SHELL GETS ITS OWN BEHAVIOUR BACK AT THE END OF THE CHAIN.**
    /// A per-accessory `savedMinimizeBehavior` cannot do this: the newcomer
    /// installs while the outgoing screen still has the bar armed, so it
    /// captures `.onScrollDown` as though that were the shell's default and
    /// hands it back on the way out — `.onScrollDown` for every tab, which is
    /// the exact hazard the restore exists to prevent. Counted per controller,
    /// the first arm records what the shell had and the last release returns it.
    @Test func theShellsOwnBehaviourSurvivesAChainOfHandOvers() {
        let controller = UITabBarController()
        controller.tabBarMinimizeBehavior = .never
        let first = SelectorAccessory(strip: PagedTabBar(titles: ["A"], style: .navigationTitle))
        let second = SelectorAccessory(strip: PagedTabBar(titles: ["B"], style: .navigationTitle))
        let third = SelectorAccessory(strip: PagedTabBar(titles: ["C"], style: .navigationTitle))

        first.install(into: controller, minimizesOnScroll: true)
        second.install(into: controller, minimizesOnScroll: true)
        first.remove(from: controller)
        third.install(into: controller, minimizesOnScroll: true)
        second.remove(from: controller)
        #expect(controller.tabBarMinimizeBehavior == .onScrollDown,
                "somebody still holds it")

        third.remove(from: controller)
        #expect(controller.tabBarMinimizeBehavior == .never,
                "the last one out gives the shell its own behaviour back")
        #expect(controller.bottomAccessory == nil)
    }

    /// A screen that installs twice — `viewWillAppear` then `viewDidAppear`,
    /// which is exactly what every host does — must not count as two owners,
    /// or the shell never gets its behaviour back.
    @Test func installingTwiceHoldsTheMinimizeOnce() {
        let controller = UITabBarController()
        controller.tabBarMinimizeBehavior = .never
        let accessory = SelectorAccessory(strip: PagedTabBar(titles: ["A"], style: .navigationTitle))

        accessory.install(into: controller, minimizesOnScroll: true)
        accessory.install(into: controller, minimizesOnScroll: true)
        accessory.remove(from: controller)
        #expect(controller.tabBarMinimizeBehavior == .never)
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
