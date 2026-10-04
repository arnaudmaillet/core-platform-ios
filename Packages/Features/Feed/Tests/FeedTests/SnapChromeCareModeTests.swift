import CoreModels
import DesignSystem
import Testing
import UIKit
@testable import Feed

/// Care Mode on a media page (#482): the emote shortcuts go, and nothing
/// around them moves.
@MainActor
@Suite(.serialized)
struct SnapChromeCareModeTests {
    private static func chrome() -> SnapChromeView {
        let chrome = SnapChromeView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        chrome.setFixedInsets(UIEdgeInsets(top: 103, left: 0, bottom: 34, right: 0))
        chrome.configure(with: FeedItemDisplayModel(
            id: PostID("post-1"),
            authorID: ProfileID("profile-1"),
            authorName: "Ana",
            metaText: "@ana · 3m",
            avatarURL: nil,
            caption: "A caption long enough to fill both of its lines beside the reserved floor.",
            mediaURL: URL(string: "mock://media/1"),
            mediaKind: .image,
            thumbnailURL: nil,
            audioText: nil
        ))
        chrome.layoutIfNeeded()
        return chrome
    }

    private static func rail(_ chrome: SnapChromeView) throws -> UIView {
        try #require(chrome.subviews.first { $0.accessibilityIdentifier == "shortcut-rail" })
    }

    @Test func theRailShowsWithoutCareMode() throws {
        let previous = CareModePreference.isOn
        defer { CareModePreference.isOn = previous }
        CareModePreference.isOn = false
        #expect(try !Self.rail(Self.chrome()).isHidden)
    }

    /// Hidden, with the same frame: the subtitle slot that stops at the
    /// rail's leading edge stays where it was.
    @Test func careModeHidesTheRailWithoutMovingAnything() throws {
        let previous = CareModePreference.isOn
        defer { CareModePreference.isOn = previous }
        CareModePreference.isOn = false
        let frameWithout = try Self.rail(Self.chrome()).frame
        CareModePreference.isOn = true
        let rail = try Self.rail(Self.chrome())
        #expect(rail.isHidden)
        #expect(rail.frame == frameWithout)
    }
}
