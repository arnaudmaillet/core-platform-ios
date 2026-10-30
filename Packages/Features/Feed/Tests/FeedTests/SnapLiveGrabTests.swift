import CoreModels
import CoreNavigation
import MediaCore
import Testing
import UIKit
@testable import Feed

/// THE LIVE GRAB (#1915, the owner 2026-10-29, after filming Instagram,
/// TikTok and Douyin): a grab moves the live page, its whole interface on
/// it — nothing fades while the finger holds it; a commit fades it inside
/// the release spring, a cancel gives it back whole.
@MainActor
struct SnapLiveGrabTests {
    private static let container = CGRect(x: 0, y: 0, width: 390, height: 844)

    private func makeCell() -> SnapFeedCell {
        let cell = SnapFeedCell(frame: Self.container)
        cell.applyChromeInsets(UIEdgeInsets(top: 103, left: 0, bottom: 34, right: 0))
        cell.configure(
            with: FeedItemDisplayModel(
                id: PostID("post-0000"), authorID: ProfileID("profile-1"), authorName: "Ava",
                metaText: "@ava · 3m", avatarURL: nil, caption: "caption",
                mediaURL: URL(string: "mock://media/0.jpg"), mediaKind: .image, thumbnailURL: nil,
                audioText: "Original sound · @ava", likeCount: 0, timestampText: "5 days"
            ),
            pipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            videoPlayback: nil
        )
        cell.layoutIfNeeded()
        return cell
    }

    private static let card = CGRect(x: 60, y: 200, width: 270, height: 585)

    /// Held: the interface rides the card — moved and scaled with the page,
    /// at full opacity — and takes no touch.
    @Test func theInterfaceRidesTheGrabWhole() throws {
        let cell = makeCell()
        let chrome = cell.debugChrome
        let resting = chrome.convert(chrome.bounds, to: cell.contentView)
        try #require(resting.width > 0)

        cell.beginLiveGrab()
        #expect(cell.isLiveGrab)
        cell.setEngagedDismissal(ZoomDismissState(progress: 0.6, card: Self.card, cornerRadius: 30, isSettling: false))

        let moved = chrome.convert(chrome.bounds, to: cell.contentView)
        #expect(moved.width < resting.width * 0.9, "the interface stood still while the page left: \(moved)")
        #expect(abs(moved.midX - Self.card.midX) < 1 && abs(moved.midY - Self.card.midY) < 1,
                "the interface is not on the card: \(moved)")
        #expect(cell.debugStageAlphas.allSatisfy { $0 == 1 }, "the interface faded under the finger")
        #expect(cell.debugStagesTakeTouches == false, "the held page takes the finger's touches")
    }

    /// A commit fades the interface in the release spring; a cancel keeps it.
    @Test(arguments: [(CGFloat(1), CGFloat(0)), (0, 1)])
    func theReleaseDecidesTheFade(_ progress: CGFloat, _ alpha: CGFloat) {
        let cell = makeCell()
        cell.beginLiveGrab()
        cell.setEngagedDismissal(ZoomDismissState(progress: 0.6, card: Self.card, cornerRadius: 30, isSettling: false))
        cell.setEngagedDismissal(ZoomDismissState(progress: progress, card: Self.card, cornerRadius: 30, isSettling: true))
        #expect(cell.debugStageAlphas.allSatisfy { $0 == alpha })
    }

    /// The end gives the page back exactly: identity, opaque, touchable.
    @Test func theEndGivesThePageBack() {
        let cell = makeCell()
        cell.beginLiveGrab()
        cell.setEngagedDismissal(ZoomDismissState(progress: 1, card: Self.card, cornerRadius: 30, isSettling: true))
        cell.endEngagedDismissal()
        #expect(!cell.isLiveGrab)
        #expect(cell.debugStageAlphas.allSatisfy { $0 == 1 })
        #expect(cell.debugStagesTakeTouches)
        #expect(cell.contentView.mask == nil)
        let chrome = cell.debugChrome
        #expect(chrome.convert(chrome.bounds, to: cell.contentView) == cell.contentView.bounds)
    }

    /// The engaged dismissal keeps its own rule: the thread recedes with the
    /// finger.
    @Test func anEngagedGrabIsNotALiveOne() {
        let cell = makeCell()
        cell.setCommentsEngaged(true)
        cell.beginEngagedDismissal()
        #expect(!cell.isLiveGrab)
        cell.beginLiveGrab()
        #expect(!cell.isLiveGrab, "a second grab began over the first")
    }
}
