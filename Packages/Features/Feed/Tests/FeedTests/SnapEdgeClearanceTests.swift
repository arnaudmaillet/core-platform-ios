import CoreModels
import DesignSystem
import Testing
import UIKit
@testable import Feed

/// ⚠️ THE EDGE STRIP AND THE TRAILING COLUMN NEVER OVERLAP (#1592, the
/// owner 2026-10-22): the emote rail, the boost station and the sound
/// bubble all stand at least `trailingEdgeGap` inside the trailing strip,
/// on every screen width.
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
    func theTrailingColumnStandsClearOfTheEdge(width: CGFloat) {
        let chrome = Self.chrome(width: width)
        let limit = width - PagedScreenDismissalPolicy.trailingEdgeZone - PagedScreenDismissalPolicy.trailingEdgeGap
        let rail = chrome.debugRailFrame
        #expect(!rail.isEmpty, "guard: the rail is laid out")
        #expect(rail.maxX <= limit + 0.5, "the rail reaches \\(rail.maxX) of \\(width)")
        #expect(chrome.debugBoostButton.convert(chrome.debugBoostButton.bounds, to: chrome).maxX <= limit + 0.5)
        #expect(chrome.debugSoundBubble.convert(chrome.debugSoundBubble.bounds, to: chrome).maxX <= limit + 0.5)
    }

    /// The strip is still wider than the 28 pt the owner's thumb landed past.
    @Test func theStripStaysWiderThanTheLeadingOne() {
        #expect(PagedScreenDismissalPolicy.trailingEdgeZone > PagedScreenDismissalPolicy.edgeZone)
        #expect(PagedScreenDismissalPolicy.trailingEdgeGap >= 8)
    }
}
