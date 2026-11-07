import Testing
import UIKit
@testable import DesignSystem

/// The app's own type scale (#2149): B, the owner's pick on his iPhone
/// (2026-11-06) — the only scale since the issue closed.
@MainActor
struct AppTypeScaleTests {
    private static let large = UITraitCollection(preferredContentSizeCategory: .large)
    private static let xxxl = UITraitCollection(preferredContentSizeCategory: .extraExtraExtraLarge)
    private static let styles: [UIFont.TextStyle] = [
        .largeTitle, .title1, .title2, .title3, .headline, .body, .callout, .subheadline, .footnote, .caption1, .caption2,
    ]

    @Test func eachStyleTakesTheScalesSizeAtTheDefaultTextSize() {
        let sizes: [CGFloat] = [32, 26, 21, 19, 16, 16, 15, 14, 13, 12, 11]
        for (style, size) in zip(Self.styles, sizes) {
            let font = UIFont.appFont(forTextStyle: style, compatibleWith: Self.large, boldText: false)
            #expect(abs(font.pointSize - size) < 0.01, "\(style.rawValue): \(font.pointSize)")
            #expect(UIFont.defaultPointSize(for: style) == size)
        }
    }

    /// Each style still grows with the text size, like the style.
    @Test func eachStyleGrowsWithTheTextSize() {
        for style in Self.styles {
            let small = UIFont.appFont(forTextStyle: style, compatibleWith: Self.large, boldText: false)
            let big = UIFont.appFont(forTextStyle: style, compatibleWith: Self.xxxl, boldText: false)
            #expect(big.pointSize > small.pointSize, "\(style.rawValue) did not grow")
        }
        // The body at XXXL: about 21–22 pt (UIFontMetrics' curve is not a
        // straight ratio), under Apple's 23.
        let body = UIFont.appFont(forTextStyle: .body, compatibleWith: Self.xxxl, boldText: false)
        let apple = UIFont.preferredFont(forTextStyle: .body, compatibleWith: Self.xxxl).pointSize
        #expect(body.pointSize > 20.5 && body.pointSize < apple, "the body at XXXL: \(body.pointSize) (Apple's \(apple))")
    }

    @Test func nothingIsUnderElevenPointsAtTheDefaultSize() {
        for style in Self.styles {
            #expect((AppTypeScale.size(for: style) ?? 0) >= AppTypeScale.floor, "\(style.rawValue)")
        }
    }

    /// Bold Text thickens it, as `preferredFont` does; headline is semibold.
    @Test func boldTextIsKept() {
        #expect(AppTypeScale.weight(for: .body, boldText: false) == .regular)
        #expect(AppTypeScale.weight(for: .body, boldText: true) == .semibold)
        #expect(AppTypeScale.weight(for: .headline, boldText: false) == .semibold)
        #expect(AppTypeScale.weight(for: .headline, boldText: true) == .bold)
        let regular = UIFont.appFont(forTextStyle: .body, compatibleWith: Self.large, boldText: false)
        let bold = UIFont.appFont(forTextStyle: .body, compatibleWith: Self.large, boldText: true)
        #expect(regular.fontName != bold.fontName || regular.fontDescriptor != bold.fontDescriptor)
    }

    /// Care Mode's floor is one step over Apple's Extra Large, so its body
    /// stays about Apple's Extra Large (19 pt).
    @Test func careModesFloorRisesOnTheAppsScale() {
        #expect(CareModePreference.minimumContentSize == .extraExtraLarge)
        let care = UITraitCollection(preferredContentSizeCategory: AppTypeScale.careModeMinimum)
        let body = UIFont.appFont(forTextStyle: .body, compatibleWith: care, boldText: false)
        #expect(abs(body.pointSize - 19) < 1.5, "Care Mode's body: \(body.pointSize)")
    }

    /// No launch argument changes the scale any more (the DEBUG switch
    /// went with #2149).
    @Test func noSwitchIsLeft() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/DesignSystem/Foundation/AppTypeScale.swift"), encoding: .utf8)
        #expect(!source.contains("ProcessInfo"))
    }

    /// A label wearing it re-scales live, like a text style.
    @Test func aLabelReScalesLive() {
        let label = UILabel()
        label.adjustsFontForContentSizeCategory = true
        label.font = UIFont.appFont(forTextStyle: .body, compatibleWith: Self.large, boldText: false)
        label.traitOverrides.preferredContentSizeCategory = .extraExtraExtraLarge
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        window.addSubview(label)
        window.isHidden = false
        defer { window.isHidden = true }
        label.layoutIfNeeded()
        #expect(label.font.pointSize > 16, "the label kept \(label.font.pointSize)")
    }
}
