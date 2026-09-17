import Testing
import UIKit
@testable import DesignSystem

/// The bar of things that DO something, and the one difference from the bar of
/// things that are CHOSEN.
///
/// ⚠️ **THE WHOLE REASON THIS TYPE EXISTS IS THE SECOND TAP**, so that is the
/// test that has to be able to fail. `IconSelectorBar.select(_:notify:)`
/// announces only when the index changes — tapping the already-selected icon is
/// silent, which is correct for a mode and useless for "cut here". A suite that
/// only asserted "a tap announces" would pass on a selector wearing this type's
/// name, and a clip could be split exactly once.
@MainActor
struct IconActionBarTests {
    private static let two = [
        IconActionBar.Item(symbolName: "scissors", accessibilityLabel: "Split"),
        IconActionBar.Item(symbolName: "speedometer", accessibilityLabel: "Speed")
    ]

    private func bar(_ items: [IconActionBar.Item] = two, width: CGFloat = 120) -> IconActionBar {
        let bar = IconActionBar(items: items)
        bar.frame = CGRect(x: 0, y: 0, width: width, height: IconActionBar.height)
        bar.setNeedsLayout()
        bar.layoutIfNeeded()
        return bar
    }

    // MARK: - Tapping

    @Test func aTapSaysWhichOne() {
        let bar = bar()
        var told: [Int] = []
        bar.onTap = { told.append($0) }

        bar.debugTap(1)

        #expect(told == [1])
    }

    /// ⚠️ **THE ONE A SELECTOR CANNOT PASS.** Two cuts at two places in the clip
    /// are two taps on the same icon, and the second one has to be heard.
    @Test func theSameItemTappedTwiceIsHeardTwice() {
        let bar = bar()
        var told: [Int] = []
        bar.onTap = { told.append($0) }

        bar.debugTap(0)
        bar.debugTap(0)
        bar.debugTap(0)

        #expect(told == [0, 0, 0], "an action has no state to return to")
    }

    // MARK: - What it can do right now

    @Test func anItemThatCannotActSaysNothingAndReadsAsOff() {
        let bar = bar()
        var told: [Int] = []
        bar.onTap = { told.append($0) }

        bar.setEnabled(false, at: 0)
        bar.debugTap(0)

        #expect(told.isEmpty, "a disabled action must not fire")
        #expect(bar.isEnabled(at: 0) == false)
    }

    @Test func anItemCanBeGivenItsActionBack() {
        let bar = bar()
        var told: [Int] = []
        bar.onTap = { told.append($0) }

        bar.setEnabled(false, at: 0)
        bar.setEnabled(true, at: 0)
        bar.debugTap(0)

        #expect(told == [0])
    }

    // MARK: - The open panel

    @Test func theItemWhosePanelIsOpenIsLit() {
        let bar = bar()

        bar.setActive(1)
        bar.layoutIfNeeded()

        let lit = bar.debugLensFrame
        #expect(lit != nil, "nothing is drawn as open")
        // The second segment, so past the first one's width.
        #expect((lit?.midX ?? 0) > IconBarMetrics.segmentSide,
                "the tint is on the wrong item: \(String(describing: lit))")
        #expect(bar.activeItem == 1)
    }

    @Test func closingThePanelTakesTheLightAway() {
        let bar = bar()
        bar.setActive(1)
        bar.layoutIfNeeded()

        bar.setActive(nil)
        bar.layoutIfNeeded()

        #expect(bar.debugLensFrame == nil)
        #expect(bar.activeItem == nil)
    }

    @Test func anItemThatIsNotThereCannotBeLit() {
        let bar = bar()

        bar.setActive(7)
        bar.layoutIfNeeded()

        #expect(bar.debugLensFrame == nil)
    }

    // MARK: - The shape it shares with the selector

    /// ⚠️ **THEY SIT AT OPPOSITE ENDS OF THE SAME TOOLBAR.** Upload's editor puts
    /// this bar in the leading slot and an `IconSelectorBar` beside it, on one
    /// baseline. A height or a segment stride that agreed by coincidence rather
    /// than by construction would misalign the two bubbles the first time either
    /// number moved.
    @Test func bothBarsAreCutToTheSameShape() {
        #expect(IconActionBar.height == IconSelectorBar.height)

        let actions = bar(Self.two)
        let selector = IconSelectorBar(items: [
            IconSelectorBar.Item(symbolName: "scissors", accessibilityLabel: "Split"),
            IconSelectorBar.Item(symbolName: "speedometer", accessibilityLabel: "Speed")
        ])

        #expect(actions.intrinsicContentSize == selector.intrinsicContentSize,
                "two items are two items: \(actions.intrinsicContentSize) vs \(selector.intrinsicContentSize)")
    }

    @Test func insideABarItDrawsNoCapsuleOfItsOwn() {
        let bar = bar()
        let wide = bar.intrinsicContentSize.width

        bar.suppressesBackdrop = true

        #expect(bar.intrinsicContentSize.width < wide,
                "the clearance the platter supplies must come off, or the ring doubles")
    }

    // MARK: - The glyphs exist

    /// ⚠️ **A SYMBOL THAT DOES NOT RESOLVE IS AN EMPTY BUTTON, NOT AN ERROR.**
    /// `UIImage(systemName:)` answers nil and the bar draws a blank square that
    /// still takes taps. This repository has shipped one
    /// (`arrow.trianglehead.counterclockwise.rotate`), which is why the runtime
    /// is asked rather than the catalogue.
    @Test func everyGlyphThisBarIsGivenResolves() {
        for item in Self.two {
            #expect(UIImage(systemName: item.symbolName) != nil, "\(item.symbolName) is not a symbol")
        }
    }
}
