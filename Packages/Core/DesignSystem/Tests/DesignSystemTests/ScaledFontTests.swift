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

    /// The baseline for a style is its DEFAULT size, whatever the current
    /// setting — the size the metrics expect, so nothing is scaled twice.
    @Test func defaultPointSizesAreTheLargeCategorysSizes() {
        #expect(UIFont.defaultPointSize(for: .body) == 17)
        #expect(UIFont.defaultPointSize(for: .footnote) == 13)
        #expect(UIFont.defaultPointSize(for: .caption2) == 11)
    }

    /// Scaling the default baseline once lands on the system's own size for
    /// the style; scaling an already-scaled size (the bug fixed in
    /// PagedTabBar and the Messages rows) would overshoot it.
    @Test func scalingTheDefaultBaselineMatchesTheSystemStyle() {
        let ax = traits(.accessibilityExtraExtraExtraLarge)
        let system = UIFont.preferredFont(forTextStyle: .body, compatibleWith: ax).pointSize
        let ours = UIFont.scaledSystemFont(ofSize: UIFont.defaultPointSize(for: .body), relativeTo: .body, compatibleWith: ax)
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
        #expect(TextSizeCeiling.contentSize(system: .large, careMode: true) == .extraLarge)
    }

    /// ⚠️ The ceiling only holds if fonts are made at the app's size. Scans
    /// the app and every package that can see DesignSystem for a bare
    /// `preferredFont(forTextStyle:)` (no traits), which reads the iPhone's
    /// setting instead of the app's.
    @Test func noFontReadsTheIPhonesTextSizeDirectly() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DesignSystemTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // DesignSystem
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
        // Packages below DesignSystem can't call `appFont`.
        let exempt = ["/MediaPlayback/", "/StickerKit/"]
        let pattern = try Regex(#"preferredFont\(forTextStyle:\s*[^,)]+\)"#)
        var offenders: [String] = []
        for folder in ["App", "Packages"] {
            let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                let path = url.path
                guard url.pathExtension == "swift", !path.contains("/.build/"), !path.contains("/Tests/"),
                      url.lastPathComponent != "ScaledFont.swift",
                      !exempt.contains(where: { path.contains($0) }) else { continue }
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                if text.contains(pattern) { offenders.append(url.lastPathComponent) }
            }
        }
        #expect(offenders.isEmpty, "bare preferredFont(forTextStyle:) in: \(offenders)")
    }
}
