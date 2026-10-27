import DesignSystem
import Testing
import UIKit
@testable import Profile

/// A loading Settings row is the row it stands for, redacted (#1769): bones
/// over a clear-inked copy of the real configuration — never "Loading…".
@MainActor
struct SettingsSkeletonRowConfigurationTests {
    @Test func aLoadingRowIsItsRowRedacted() throws {
        var content = UIListContentConfiguration.subtitleCell()
        content.text = "Verification"
        content.secondaryText = "Your verification status"
        let view = SettingsSkeletonRowConfiguration(redacting: content).makeContentView()
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 64)
        view.layoutIfNeeded()
        let bones = view.subviews.filter { $0 is SkeletonBoneView && !$0.isHidden }
        #expect(bones.count == 2, "a bone for the title and one for the subtitle")
        #expect(view.accessibilityLabel == "Loading")
        func labels(in view: UIView) -> [UILabel] {
            view.subviews.flatMap { ($0 as? UILabel).map { [$0] } ?? labels(in: $0) }
        }
        #expect(labels(in: view).allSatisfy { $0.textColor == .clear }, "the sample text shows")
    }

    @Test func aOneLineSampleIsOneBone() {
        let view = SettingsSkeletonRowConfiguration(sample: "A row of this list").makeContentView()
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 44)
        view.layoutIfNeeded()
        #expect(view.subviews.filter { $0 is SkeletonBoneView && !$0.isHidden }.count == 1)
    }
}
