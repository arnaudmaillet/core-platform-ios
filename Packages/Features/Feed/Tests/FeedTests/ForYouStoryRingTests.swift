import DesignSystem
import Testing
import UIKit
@testable import Feed

/// The unseen-story ring of For You's friends row (#1169): raspberry →
/// violet, no mint (#2089, the owner 2026-11-03), along the brand's
/// diagonal, in both appearances.
@MainActor
struct ForYouStoryRingTests {
    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func theRingRunsFromTheRaspberryToTheViolet(_ style: UIUserInterfaceStyle) {
        let cell = ForYouStoryCell(frame: CGRect(x: 0, y: 0, width: 80, height: 100))
        cell.overrideUserInterfaceStyle = style
        cell.layoutIfNeeded()
        let ring = cell.debugRingGradient
        let traits = UITraitCollection(userInterfaceStyle: style)
        #expect(ring.colors == Palette.storyRingGradient.map { $0.resolvedColor(with: traits).cgColor })
        #expect(ring.colors.count == 2, "the mint is back")
        #expect(ring.locations == [0, 1])
        #expect(ring.start == Palette.brandGradientStart && ring.end == Palette.brandGradientEnd)
    }
}
