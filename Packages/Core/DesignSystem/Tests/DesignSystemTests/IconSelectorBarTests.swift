import Testing
import UIKit
@testable import DesignSystem

/// Choosing an icon, by tap and by slide.
///
/// ⚠️ **EVERY "IT ANNOUNCES" TEST HERE IS PAIRED WITH A "IT STAYS QUIET" ONE.**
/// On its own, "a slide announced the landing" is equally true of a control that
/// announces every settle — including one that wandered off an icon and came
/// back, which changed nothing. The pairs are what make either half able to fail.
///
/// A gesture recognizer cannot be driven from a unit test, so the drag is entered
/// through the same three functions the recognizer calls (`debugBeginDrag`,
/// `debugDrag`, `debugEndDrag`) — the shipping path, not a copy of it. What that
/// CANNOT establish is that a real finger produces the same landing; that is
/// checked on a device.
@MainActor
struct IconSelectorBarTests {
    private static let four = [
        IconSelectorBar.Item(symbolName: "wand.and.stars", accessibilityLabel: "Effects"),
        IconSelectorBar.Item(symbolName: "textformat", accessibilityLabel: "Text"),
        IconSelectorBar.Item(symbolName: "face.smiling", accessibilityLabel: "Stickers"),
        IconSelectorBar.Item(symbolName: "camera.filters", accessibilityLabel: "Filters")
    ]

    private func bar(_ items: [IconSelectorBar.Item] = four, width: CGFloat = 200) -> IconSelectorBar {
        let bar = IconSelectorBar(items: items)
        bar.frame = CGRect(x: 0, y: 0, width: width, height: IconSelectorBar.height)
        bar.setNeedsLayout()
        bar.layoutIfNeeded()
        return bar
    }

    private func lensCentre(_ bar: IconSelectorBar) -> CGFloat {
        bar.debugLensCentreX - bar.debugStripOffset
    }

    // MARK: - Tapping

    @Test func aTapChoosesAndSaysSo() {
        let bar = bar()
        var told: [Int] = []
        bar.onSelect = { told.append($0) }

        bar.debugTap(2)

        #expect(bar.selectedIndex == 2)
        #expect(told == [2], "one announcement, carrying which one")
    }

    /// ⚠️ THE WITNESS. Without it, "a tap announces" is true of a control that
    /// announces on every touch, including one that chose nothing.
    @Test func aTapOnTheChosenIconSaysNothing() {
        let bar = bar()
        bar.debugTap(2)
        var told = 0
        bar.onSelect = { _ in told += 1 }

        bar.debugTap(2)

        #expect(told == 0, "nothing changed, so nothing is announced")
        #expect(bar.selectedIndex == 2, "and it stays chosen")
    }

    @Test func choosingProgrammaticallyCanStaySilent() {
        let bar = bar()
        var told = 0
        bar.onSelect = { _ in told += 1 }

        bar.select(3, notify: false)

        #expect(bar.selectedIndex == 3, "the choice landed")
        #expect(told == 0, "adopting a stored choice is not news for the host")
    }

    // MARK: - Sliding — the reported bug

    /// ⚠️ **THIS IS THE DEFECT THAT PROMPTED THE COMPONENT.** On `PagedTabBar` a
    /// drag announced nothing, because where the pages land is a PAGER's answer —
    /// correct for its seven hosts, useless for one with no pager, where the pill
    /// landed on the right icon and the screen was never told.
    @Test func aSlideThatLandsElsewhereSaysSoWithoutATap() {
        let bar = bar()
        var told: [Int] = []
        bar.onSelect = { told.append($0) }

        let start = lensCentre(bar)
        bar.debugBeginDrag(atX: start)
        for step in 1...4 {
            bar.debugDrag(toX: start + CGFloat(step) * 12, after: 0.05)
        }
        bar.debugEndDrag()

        #expect(told.count == 1, "exactly one landing, not one per frame: \(told)")
        #expect(told.first == bar.selectedIndex, "and it agrees with the control")
        #expect(bar.selectedIndex != 0, "witness: it really left the icon it began on")
    }

    /// ⚠️ THE WITNESS FOR THE ONE ABOVE.
    @Test func aSlideThatComesHomeSaysNothing() {
        let bar = bar()
        var told = 0
        bar.onSelect = { _ in told += 1 }

        let start = lensCentre(bar)
        bar.debugBeginDrag(atX: start)
        bar.debugDrag(toX: start + 14, after: 0.05)
        // Home slowly, so the release carries no throw of its own.
        bar.debugDrag(toX: start, after: 0.5)
        bar.debugEndDrag()

        #expect(told == 0)
        #expect(bar.selectedIndex == 0)
    }

    @Test func aPressThatNeverTravelledIsATapAndSettlesNothing() {
        let bar = bar()
        var told = 0
        bar.onSelect = { _ in told += 1 }

        let start = lensCentre(bar)
        bar.debugBeginDrag(atX: start)
        // Under the slop of 3pt: a finger resting on the icon it already has.
        bar.debugDrag(toX: start + 2, after: 0.05)
        bar.debugEndDrag()

        #expect(told == 0, "a rest is not a slide")
        #expect(bar.debugStripAcceptsScrolling, "and the strip has its scrolling back")
    }

    // MARK: - Whose touch is it

    /// ⚠️ **A TOUCH OFF THE PILL BELONGS TO THE STRIP.** Claim every touch and the
    /// viewer can never scroll a crowded bar by finger — which is the whole reason
    /// the icons are reachable at all once there are enough of them.
    /// ⚠️ **PAIRED, AND THE SECOND HALF IS THE LOAD-BEARING ONE.** A control that
    /// claimed every touch would pass the first assertion and make a crowded bar
    /// unscrollable by finger — which is the whole way the far icons are reached
    /// once there are more of them than fit.
    @Test func onlyATouchOnThePillPicksItUp() {
        let bar = bar()
        let onPill = CGPoint(x: bar.debugLensFrame.midX, y: bar.debugLensFrame.midY)
        let farRight = CGPoint(x: bar.debugLensFrame.maxX + 60, y: bar.debugLensFrame.midY)

        #expect(bar.debugAcceptsGrab(at: onPill), "the pill is draggable where it is")
        #expect(bar.debugAcceptsGrab(at: farRight) == false,
                "and a touch on a plain icon belongs to the strip, not to the pill")
    }

    @Test func aSingleIconIsNotDraggable() {
        let one = [IconSelectorBar.Item(symbolName: "crop", accessibilityLabel: "Crop")]
        let bar = bar(one)
        let onPill = CGPoint(x: bar.debugLensFrame.midX, y: bar.debugLensFrame.midY)

        #expect(bar.debugAcceptsGrab(at: onPill) == false, "there is nowhere to slide to")
    }

    // MARK: - The strip

    @Test func theStripStandsDownOnlyForTheDrag() {
        let bar = bar()
        #expect(bar.debugStripAcceptsScrolling, "guard: it scrolls before the drag")

        let start = lensCentre(bar)
        bar.debugBeginDrag(atX: start)
        #expect(bar.debugStripAcceptsScrolling == false, "suspended for the gesture")

        bar.debugEndDrag()
        #expect(bar.debugStripAcceptsScrolling, "and handed back after it")
    }

    @Test func theWidthGrowsWithTheIconsSoOverflowIsReal() {
        let two = Array(Self.four.prefix(2))
        let narrow = bar(two).intrinsicContentSize.width
        let wide = bar(Self.four).intrinsicContentSize.width

        #expect(wide > narrow, "four icons ask for more room than two: \(wide) vs \(narrow)")
        // 4 × 36 + 3 × 2 + 2 × 2 = 154 — five would be 192, where four WORDS did
        // not fit the editor's toolbar at all.
        #expect(abs(wide - 154) < 0.5, "and the arithmetic is the stated one: \(wide)")
    }

    // MARK: - Where a release lands

    /// ⚠️ **THE REPORTED DEFECT, IN ARITHMETIC.** The pager figure — half a second
    /// of throw — is sized for pages a screen wide. On a 38pt strip a finger still
    /// drifting imperceptibly at release projects more than a whole icon past
    /// where it stopped.
    @Test func placingThePillLeavesItWhereItWasPlaced() {
        let bar = bar()

        // Stopped on icon 2, with the small residual a real finger always has.
        #expect(bar.debugLanding(from: 2, speed: 0) == 2)
        #expect(bar.debugLanding(from: 2.05, speed: 1.2) == 2, "a drift is not a throw")
        #expect(bar.debugLanding(from: 1.9, speed: -1.2) == 2)
    }

    /// ⚠️ AND THE WITNESS: a real flick still carries, or "precise" would just
    /// mean "inert".
    @Test func aFlickCarriesExactlyOneIcon() {
        let bar = bar()

        #expect(bar.debugLanding(from: 1.2, speed: 9) == 2, "forward, one along")
        #expect(bar.debugLanding(from: 1.8, speed: -9) == 1, "backward, one along")
        #expect(bar.debugLanding(from: 1.2, speed: 40) == 2,
                "and a hard flick is still ONE — there is no gesture meaning 'three along'")
    }

    @Test func aLandingNeverLeavesTheIconsThatExist() {
        let bar = bar()
        #expect(bar.debugLanding(from: 3, speed: 40) == 3, "nothing past the last")
        #expect(bar.debugLanding(from: 0, speed: -40) == 0, "nor before the first")
    }

    // MARK: - What the icon shows

    /// ⚠️ **THE PILL IS CENTRED ON BOTH AXES, AND ONLY ONE OF THEM HAD A TEST.**
    /// The vertical placement was wrong for a while — two clearances added instead
    /// of one centring — and nothing noticed, because every assertion here read
    /// `midX`. A pill can be perfectly placed horizontally and sit flush against
    /// the capsule's floor.
    @Test func theSelectionBackgroundIsCentredInItsSegment() throws {
        let bar = bar()
        let alignment = try #require(bar.debugLensAlignment)

        #expect(abs(alignment.lens.midX - alignment.segment.midX) < 0.5,
                "horizontally: \(alignment)")
        #expect(abs(alignment.lens.midY - alignment.segment.midY) < 0.5,
                "and vertically, which is the half that had no test: \(alignment)")
        #expect(alignment.lens.width < alignment.segment.width,
                "witness: the pill really is inset inside its segment")
    }

    /// ⚠️ **THE REASON THE PILL LOOKED THICKER THAN EVERY OTHER SELECTOR.** In a
    /// bar the platter supplies the clearance and is 4pt larger than the view it
    /// hosts; a clearance of our own stacks on top of it, so the pill read 6pt off
    /// the edge where the rest of the app reads 4. `PagedTabBar` zeroes its own
    /// padding for exactly this reason, and this is the same rule stated here.
    @Test func thePillTakesTheWholeSegmentWhenABarSuppliesTheCapsule() {
        let bar = bar()
        let standalone = bar.debugLensSide
        #expect(standalone < 36, "guard: on its own it keeps a clearance: \(standalone)")

        bar.suppressesBackdrop = true
        bar.setNeedsLayout()
        bar.layoutIfNeeded()

        #expect(bar.debugLensSide == 36,
                "inside a bar the platter is the only clearance: \(bar.debugLensSide)")
        #expect(bar.debugHasCapsuleMaterial == false, "and this view draws no capsule of its own")
    }

    @Test func theChosenIconIsDrawnFilled() {
        let bar = bar()
        #expect(bar.debugIsSelectedFilled, "the selected segment carries an image")
        bar.debugTap(3)
        #expect(bar.selectedIndex == 3)
        #expect(bar.debugIsSelectedFilled, "and still does after the choice moves")
    }

    @Test func replacingTheItemsKeepsTheSelectionInRange() {
        let bar = bar()
        bar.debugTap(3)
        #expect(bar.selectedIndex == 3)

        bar.setItems(Array(Self.four.prefix(2)))

        #expect(bar.debugItemCount == 2)
        #expect(bar.selectedIndex <= 1, "an index into a list that just got shorter")
    }
}
