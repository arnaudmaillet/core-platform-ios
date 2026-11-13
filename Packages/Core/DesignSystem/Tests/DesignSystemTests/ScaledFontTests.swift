import Testing
import UIKit
@testable import DesignSystem

/// Fonts designed at the default text size that follow Dynamic Type (#482).
@MainActor
struct ScaledFontTests {
    private func traits(_ category: UIContentSizeCategory) -> UITraitCollection {
        UITraitCollection(preferredContentSizeCategory: category)
    }

    @Test func theDesignedSizeHoldsAtTheDefaultTextSize() {
        let font = UIFont.scaledSystemFont(ofSize: 13, weight: .semibold, relativeTo: .footnote, compatibleWith: traits(.large))
        #expect(font.pointSize == 13)
        let digits = UIFont.scaledMonospacedDigitSystemFont(ofSize: 15, relativeTo: .subheadline, compatibleWith: traits(.large))
        #expect(digits.pointSize == 15)
    }

    /// A style's monospaced digits (#2329) are the style at the app's size —
    /// the same size and weight as `appFont`, growing with the text size —
    /// and a button's words read the same way: the voice panel's timer at
    /// its speed chip's size.
    @Test func monospacedDigitsAreTheStylesSize() {
        for category in [UIContentSizeCategory.large, .extraSmall, .extraExtraExtraLarge] {
            let digits = UIFont.appMonospacedDigitFont(forTextStyle: .subheadline, compatibleWith: traits(category))
            let words = UIFont.appFont(forTextStyle: .subheadline, compatibleWith: traits(category))
            #expect(digits.pointSize == words.pointSize, "\(category): \(digits.pointSize) vs \(words.pointSize)")
        }
        let large = UIFont.appMonospacedDigitFont(forTextStyle: .subheadline, compatibleWith: traits(.large))
        let huge = UIFont.appMonospacedDigitFont(forTextStyle: .subheadline, compatibleWith: traits(.extraExtraExtraLarge))
        #expect(huge.pointSize > large.pointSize, "the digits don't grow with the text size")
        let chip = AppButton.titleFont(for: .row)
        let timer = AppButton.titleFont(for: .row, monospacedDigits: true)
        #expect(timer.pointSize == chip.pointSize && timer.familyName == chip.familyName)
        // Monospaced: every digit as wide as every other.
        let widths = ["1", "8", "0"].map { ($0 as NSString).size(withAttributes: [.font: timer]).width }
        #expect(Set(widths.map { ($0 * 100).rounded() }).count == 1, "\(widths)")
    }

    @Test func itGrowsAndShrinksWithTheViewersChoice() {
        let small = UIFont.scaledSystemFont(ofSize: 13, relativeTo: .footnote, compatibleWith: traits(.extraSmall))
        let large = UIFont.scaledSystemFont(ofSize: 13, relativeTo: .footnote, compatibleWith: traits(.accessibilityExtraExtraExtraLarge))
        #expect(small.pointSize < 13)
        #expect(large.pointSize > 26)
    }

    @Test func aCapStopsTheGrowth() {
        let capped = UIFont.scaledSystemFont(
            ofSize: 13, relativeTo: .footnote, maximumPointSize: 17, compatibleWith: traits(.accessibilityExtraExtraExtraLarge)
        )
        #expect(capped.pointSize == 17)
    }

    /// The baseline for a style is its DEFAULT size on the app's scale (B,
    /// #2149), whatever the current setting — the size the metrics expect,
    /// so nothing is scaled twice.
    @Test func defaultPointSizesAreTheLargeCategorysSizes() {
        #expect(UIFont.defaultPointSize(for: .body) == 16)
        #expect(UIFont.defaultPointSize(for: .footnote) == 13)
        #expect(UIFont.defaultPointSize(for: .caption2) == 11)
    }

    /// Scaling the default baseline once lands on the system's own size for
    /// the style; scaling an already-scaled size (the bug fixed in
    /// PagedTabBar and the Messages rows) would overshoot it.
    @Test func scalingTheDefaultBaselineMatchesTheSystemStyle() {
        let ax = traits(.accessibilityExtraExtraExtraLarge)
        let system = UIFont.preferredFont(forTextStyle: .body, compatibleWith: ax).pointSize
        let ours = UIFont.scaledSystemFont(
            ofSize: 17, relativeTo: .body, compatibleWith: ax // Apple's body at Large
        )
        // UIFontMetrics' curve for a custom font tracks the system's own sizes
        // closely but not to the point; the overshoot below is the bug.
        #expect(abs(ours.pointSize - system) / system < 0.15, "\(ours.pointSize) vs \(system)")
        let doubled = UIFont.scaledSystemFont(ofSize: system, relativeTo: .body, compatibleWith: ax)
        #expect(doubled.pointSize > system * 2)
    }

    /// The ceiling: nothing above XXXL, Care Mode's floor below it.
    @Test func theAppNeverDrawsAboveXXXL() {
        #expect(TextSizeCeiling.contentSize(system: .accessibilityExtraExtraExtraLarge, careMode: false) == .extraExtraExtraLarge)
        #expect(TextSizeCeiling.contentSize(system: .accessibilityMedium, careMode: true) == .extraExtraExtraLarge)
        #expect(TextSizeCeiling.contentSize(system: .large, careMode: false) == .large)
        #expect(TextSizeCeiling.contentSize(system: .large, careMode: true) == .extraExtraLarge)
    }
}
