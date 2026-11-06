import Testing
import UIKit
@testable import DesignSystem

/// The app's own type scale (#2149): the owner compares A and B on a device;
/// until then Apple's sizes are drawn.
@MainActor
struct AppTypeScaleTests {
    private static let large = UITraitCollection(preferredContentSizeCategory: .large)
    private static let xxxl = UITraitCollection(preferredContentSizeCategory: .extraExtraExtraLarge)
    private static let styles: [UIFont.TextStyle] = [
        .largeTitle, .title1, .title2, .title3, .headline, .body, .callout, .subheadline, .footnote, .caption1, .caption2,
    ]

    @Test func eachStyleTakesTheScalesSizeAtTheDefaultTextSize() {
        let social: [CGFloat] = [30, 24, 20, 18, 15, 15, 14, 13, 12, 11, 11]
        let moderate: [CGFloat] = [32, 26, 21, 19, 16, 16, 15, 14, 13, 12, 11]
        for (style, (a, b)) in zip(Self.styles, zip(social, moderate)) {
            let fontA = UIFont.appFont(forTextStyle: style, scale: .social, compatibleWith: Self.large, boldText: false)
            let fontB = UIFont.appFont(forTextStyle: style, scale: .moderate, compatibleWith: Self.large, boldText: false)
            #expect(abs(fontA.pointSize - a) < 0.01, "A \(style.rawValue): \(fontA.pointSize)")
            #expect(abs(fontB.pointSize - b) < 0.01, "B \(style.rawValue): \(fontB.pointSize)")
            #expect(UIFont.defaultPointSize(for: style, scale: .social) == a)
        }
    }

    /// Until the owner picks, Apple's sizes: nothing changes for anyone.
    @Test func applesScaleIsTheDefaultAndDrawsPreferredFont() {
        #expect(AppTypeScale.current == .apple)
        for style in Self.styles {
            let font = UIFont.appFont(forTextStyle: style, scale: .apple, compatibleWith: Self.large)
            #expect(font.pointSize == UIFont.preferredFont(forTextStyle: style, compatibleWith: Self.large).pointSize)
        }
    }

    /// Each style still grows with the text size, like the style.
    @Test func eachStyleGrowsWithTheTextSize() {
        for scale in [AppTypeScale.social, .moderate] {
            for style in Self.styles {
                let small = UIFont.appFont(forTextStyle: style, scale: scale, compatibleWith: Self.large, boldText: false)
                let big = UIFont.appFont(forTextStyle: style, scale: scale, compatibleWith: Self.xxxl, boldText: false)
                #expect(big.pointSize > small.pointSize, "\(scale) \(style.rawValue) did not grow")
            }
        }
        // A's body at XXXL: 15 × 23 / 17 ≈ 20 pt, against 23 on Apple's.
        let body = UIFont.appFont(forTextStyle: .body, scale: .social, compatibleWith: Self.xxxl, boldText: false)
        #expect(abs(body.pointSize - 15 * 23 / 17) < 0.6)
    }

    @Test func nothingIsUnderElevenPointsAtTheDefaultSize() {
        for scale in AppTypeScale.allCases where scale != .apple {
            for style in Self.styles {
                #expect((scale.size(for: style) ?? 0) >= AppTypeScale.floor, "\(scale) \(style.rawValue)")
            }
        }
    }

    /// Bold Text thickens it, as `preferredFont` does; headline is semibold.
    @Test func boldTextIsKept() {
        #expect(AppTypeScale.weight(for: .body, boldText: false) == .regular)
        #expect(AppTypeScale.weight(for: .body, boldText: true) == .semibold)
        #expect(AppTypeScale.weight(for: .headline, boldText: false) == .semibold)
        #expect(AppTypeScale.weight(for: .headline, boldText: true) == .bold)
        let regular = UIFont.appFont(forTextStyle: .body, scale: .social, compatibleWith: Self.large, boldText: false)
        let bold = UIFont.appFont(forTextStyle: .body, scale: .social, compatibleWith: Self.large, boldText: true)
        #expect(regular.fontName != bold.fontName || regular.fontDescriptor != bold.fontDescriptor)
    }

    /// Care Mode's floor goes one step up on the app's scale, so its body
    /// stays about Apple's Extra Large (19 pt).
    @Test func careModesFloorRisesOnTheAppsScale() {
        #expect(AppTypeScale.apple.careModeMinimum == .extraLarge)
        #expect(AppTypeScale.social.careModeMinimum == .extraExtraLarge)
        let care = UITraitCollection(preferredContentSizeCategory: AppTypeScale.moderate.careModeMinimum)
        let body = UIFont.appFont(forTextStyle: .body, scale: .moderate, compatibleWith: care, boldText: false)
        #expect(abs(body.pointSize - 19) < 1.5, "Care Mode's body on B: \(body.pointSize)")
    }

    /// A label wearing it re-scales live, like a text style.
    @Test func aLabelReScalesLive() {
        let label = UILabel()
        label.adjustsFontForContentSizeCategory = true
        label.font = UIFont.appFont(forTextStyle: .body, scale: .social, compatibleWith: Self.large, boldText: false)
        label.traitOverrides.preferredContentSizeCategory = .extraExtraExtraLarge
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        window.addSubview(label)
        window.isHidden = false
        defer { window.isHidden = true }
        label.layoutIfNeeded()
        #expect(label.font.pointSize > 15, "the label kept \(label.font.pointSize)")
    }
}
