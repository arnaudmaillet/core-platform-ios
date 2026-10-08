import CoreModels
import Foundation
import MediaPlayback
import Testing
@testable import Feed

/// A post's page player started at touch-down on its map marker (#646).
@MainActor
struct FlightPlaybackWarmTests {
    private func entry(_ mimes: [String]) -> FeedEntry {
        FeedEntry(
            post: Post(
                id: PostID("post-new-01"), authorID: ProfileID("prof-1"), caption: "",
                attachments: mimes.enumerated().map { index, mime in
                    MediaAttachment(
                        url: URL(string: "https://example.com/\(index).\(mime.hasPrefix("video") ? "mp4" : "jpg")"),
                        thumbnailURL: nil, mimeType: mime, pixelWidth: 720, pixelHeight: 1280
                    )
                },
                publishedAt: Date(timeIntervalSince1970: 0)
            ),
            author: AuthorSummary(id: ProfileID("prof-1"), handle: "ava", displayName: "Ava", avatarURL: nil)
        )
    }

    @Test("A post that opens on a clip warms that clip, under the post's own scope — what its page will ask for")
    func theHeadClipIsWarmed() throws {
        let single = try #require(FlightPlaybackWarm.warmableClip(of: entry(["video/mp4"])))
        #expect(single.url == URL(string: "https://example.com/0.mp4"))
        #expect(single.scope == "post-new-01")
        // A collection opens on its head page, which plays like a single clip.
        let collection = try #require(FlightPlaybackWarm.warmableClip(of: entry(["video/mp4", "image/jpeg"])))
        #expect(collection.url == URL(string: "https://example.com/0.mp4"))
    }

    @Test("Nothing to warm for a photo, a text post, or a collection that opens on a photo")
    func nothingToWarm() {
        #expect(FlightPlaybackWarm.warmableClip(of: entry(["image/jpeg"])) == nil)
        #expect(FlightPlaybackWarm.warmableClip(of: entry([])) == nil)
        #expect(FlightPlaybackWarm.warmableClip(of: entry(["image/jpeg", "video/mp4"])) == nil)
    }

    @Test("A touch that gives up stops the player")
    func aCancelledWarmLeavesNothing() async throws {
        let pool = VideoPlaybackController(source: StubSource(), poolSize: 2, capacity: 2)
        let clip = URL(string: "mock://video/clip-46")!
        let warm = FlightPlaybackWarm(pool: pool, url: clip, scope: "post-new-01")
        warm.start(at: 1.6)
        for _ in 0..<50 where pool.playerCountByURL[clip] == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(pool.playerCountByURL[clip] == 1, "the premise: the warm started a player")

        warm.end(opened: false)
        // Wiping the start the stop files is `forgetStart`'s, pinned in
        // MediaPlayback's `RepeatPlayTests`.
        #expect(pool.playerCountByURL[clip] == nil)
    }

    private struct StubSource: VideoSource {
        func playableURL(for url: URL) async throws -> URL {
            FileManager.default.temporaryDirectory.appendingPathComponent("stub.mp4")
        }
    }
}
