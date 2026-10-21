import CoreModels
import Foundation
import MediaCore
import MediaPlayback
import Testing
import UIKit
@testable import Feed

/// The clip bar's feed belongs to the page on show, and only to it (#1532).
@MainActor
@Suite(.serialized)
struct SnapPlayheadFeedTests {
    private struct StubSource: VideoSource {
        func playableURL(for url: URL) async throws -> URL {
            FileManager.default.temporaryDirectory.appendingPathComponent("stub.mp4")
        }
    }

    private func videoCell(_ id: String, pool: VideoPlaybackController) -> SnapFeedCell {
        let cell = SnapFeedCell(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        cell.configure(
            with: FeedItemDisplayModel(
                id: PostID(id), authorID: ProfileID("a"), authorName: "Ava", metaText: "",
                avatarURL: nil, caption: "A clip", mediaURL: URL(string: "mock://video/\(id)")!, mediaKind: .video,
                thumbnailURL: nil, audioText: nil, likeCount: 0
            ),
            pipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            videoPlayback: pool
        )
        cell.layoutIfNeeded()
        return cell
    }

    /// ⚠️ A PAGE THAT RESIGNS STOPS ITS FEED; the next one starts its own —
    /// no display link outlives the page it fed.
    @Test func aResigningPageStopsItsFeedAndTheNextStartsItsOwn() {
        let pool = VideoPlaybackController(source: StubSource(), poolSize: 2, capacity: 2)
        let first = videoCell("first", pool: pool)
        let second = videoCell("second", pool: pool)

        first.willBecomeActive()
        #expect(first.debugIsFeedingPlayhead, "the page on show feeds no bar")
        #expect(!second.debugIsFeedingPlayhead)

        first.didResignActive(releasingPlayback: true)
        second.willBecomeActive()
        #expect(!first.debugIsFeedingPlayhead, "the page that left still feeds its bar")
        #expect(second.debugIsFeedingPlayhead, "the page on show feeds no bar")

        second.didResignActive(releasingPlayback: true)
        #expect(!second.debugIsFeedingPlayhead)
    }
}
