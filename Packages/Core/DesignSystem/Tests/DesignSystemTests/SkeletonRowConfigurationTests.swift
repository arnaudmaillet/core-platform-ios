import Testing
import UIKit
@testable import DesignSystem

/// A loading list row is the row it stands for, redacted (#1769): bones over
/// a clear-inked copy of the real configuration — never "Loading…".
@MainActor
struct SkeletonRowConfigurationTests {
    private func bones(in view: UIView) -> [SkeletonBoneView] {
        view.subviews.compactMap { $0 as? SkeletonBoneView }.filter { !$0.isHidden }
    }

    @Test func aLoadingRowIsItsRowRedacted() throws {
        var content = UIListContentConfiguration.subtitleCell()
        content.text = "Verification"
        content.secondaryText = "Your verification status"
        let view = SkeletonRowConfiguration(redacting: content).makeContentView()
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 64)
        view.layoutIfNeeded()
        #expect(bones(in: view).count == 2, "a bone for the title and one for the subtitle")
        #expect(view.accessibilityLabel == "Loading")
        func labels(in view: UIView) -> [UILabel] {
            view.subviews.flatMap { ($0 as? UILabel).map { [$0] } ?? labels(in: $0) }
        }
        #expect(labels(in: view).allSatisfy { $0.textColor == .clear }, "the sample text shows")
    }

    @Test func aOneLineSampleIsOneBone() {
        let view = SkeletonRowConfiguration(sample: "A row of this list").makeContentView()
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 44)
        view.layoutIfNeeded()
        #expect(bones(in: view).count == 1)
    }

    /// A value row (`valueCell()`): the label leading, the value trailing —
    /// Account's and Edit Profile's rows.
    @Test func aValueRowIsTwoBonesApart() throws {
        var content = UIListContentConfiguration.valueCell()
        content.text = "Email"
        content.secondaryText = "name@example.com"
        let view = SkeletonRowConfiguration(redacting: content).makeContentView()
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 44)
        view.layoutIfNeeded()
        let shown = bones(in: view).sorted { $0.frame.minX < $1.frame.minX }
        try #require(shown.count == 2)
        #expect(shown[0].frame.maxX < shown[1].frame.minX, "the value stands apart from the label")
        #expect(shown[1].frame.maxX > 300, "the value sits at the trailing edge")
    }

    /// A row with a trailing accessory (the wallet's amount) and a thumbnail
    /// (a stake): a bone where the amount stands, the thumbnail's corner.
    @Test func aTrailingBoneAndAThumbnail() throws {
        var content = UIListContentConfiguration.subtitleCell()
        content.text = "Staked on a post"
        content.secondaryText = "Today"
        content.image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { _ in }
        content.imageProperties.cornerRadius = 8
        content.imageProperties.maximumSize = CGSize(width: 40, height: 40)
        content.imageProperties.reservedLayoutSize = CGSize(width: 40, height: 40)
        let view = SkeletonRowConfiguration(redacting: content, trailingBoneWidth: 44).makeContentView()
        // A thumbnail row's height (the stake rows'): a shorter one squeezes
        // the picture.
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 80)
        view.layoutIfNeeded()
        let shown = bones(in: view)
        #expect(shown.count == 4, "image, title, subtitle and the amount")
        let trailing = try #require(shown.max { $0.frame.maxX < $1.frame.maxX })
        #expect(abs(trailing.bounds.width - 44) < 0.5)
        let image = try #require(shown.min { $0.frame.minX < $1.frame.minX })
        #expect(abs(image.layer.cornerRadius - 8) < 0.5, "the thumbnail's corner, not a symbol's")
        #expect(abs(image.bounds.width - 40) < 0.5, "the thumbnail's side, got \(image.bounds.size)")
    }
}
