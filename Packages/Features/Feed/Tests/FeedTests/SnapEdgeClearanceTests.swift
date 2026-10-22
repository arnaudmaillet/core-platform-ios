import CoreModels
import DesignSystem
import Testing
import UIKit
@testable import Feed

/// ⚠️ THE TRAILING COLUMN STANDS AT THE EDGE, WHERE IT ALWAYS STOOD (the
/// owner, 2026-10-22): #1592 had pushed the emote rail, the like bubble and
/// the sound bubble inboard to clear the edge strip, and that is reverted —
/// the column IS the edge for a leftward drag instead
/// (`SnapFeedViewController.isOnTrailingColumn`).
@MainActor
@Suite(.serialized)
struct SnapEdgeClearanceTests {
    private static func chrome(width: CGFloat) -> SnapChromeView {
        let chrome = SnapChromeView(frame: CGRect(x: 0, y: 0, width: width, height: 844))
        chrome.setFixedInsets(UIEdgeInsets(top: 103, left: 0, bottom: 34, right: 0))
        chrome.configure(with: FeedItemDisplayModel(
            id: PostID("post-1"), authorID: ProfileID("profile-1"), authorName: "Ana",
            metaText: "@ana · 3m", avatarURL: nil, caption: "A caption.",
            mediaURL: URL(string: "mock://media/1"), mediaKind: .image,
            thumbnailURL: nil, audioText: nil
        ))
        chrome.layoutIfNeeded()
        return chrome
    }

    @Test(arguments: [375.0, 393.0, 402.0, 440.0])
    func theTrailingColumnStandsAtTheEdge(width: CGFloat) {
        let chrome = Self.chrome(width: width)
        let edge = width - chrome.layoutMargins.right - Spacing.md
        let rail = chrome.debugRailFrame
        #expect(!rail.isEmpty, "guard: the rail is laid out")
        #expect(abs(rail.maxX - edge) < 0.5, "the rail stands at \(rail.maxX), not \(edge)")
        let boost = chrome.debugBoostButton.convert(chrome.debugBoostButton.bounds, to: chrome)
        #expect(abs(boost.maxX - edge) < 0.5, "the like bubble stands at \(boost.maxX)")
    }

    /// The strip is back at 44 pt, wider than the leading 28 pt one.
    @Test func theStripIsFortyFourPoints() {
        #expect(PagedScreenDismissalPolicy.trailingEdgeZone == 44)
        #expect(PagedScreenDismissalPolicy.trailingEdgeZone > PagedScreenDismissalPolicy.edgeZone)
    }
}
