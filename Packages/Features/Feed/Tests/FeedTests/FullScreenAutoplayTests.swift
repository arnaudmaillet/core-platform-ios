import CoreModels
import CoreStorage
import DesignSystem
import Foundation
import MediaCore
import MediaPlayback
import Testing
import UIKit
@testable import Feed

/// A post opened full screen always plays (#702): Autoplay and Power Saving
/// govern grids, rails and previews, never the post the viewer opened.
@MainActor
@Suite(.serialized)
struct FullScreenAutoplayTests {
    private struct StubSource: VideoSource {
        func playableURL(for url: URL) async throws -> URL {
            FileManager.default.temporaryDirectory.appendingPathComponent("stub.mp4")
        }
    }

    private static let clip = URL(string: "mock://video/fullscreen")!

    private func settle(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    /// ⚠️ AUTOPLAY NEVER, NOT POWER SAVING: Power Saving is app-wide state
    /// that every suite running beside this one reads (motion, emojis, the
    /// band). The cell reads neither — `MediaPlaybackPolicy.autoplays`, which
    /// folds both, is the only door, and this closes it.
    @Test func aFullScreenPostPlaysWithAutoplayNever() async {
        let previousStore = MediaPlaybackPolicy.store
        defer { MediaPlaybackPolicy.store = previousStore }
        let store = MediaPlaybackPreferencesStore(defaults: UserDefaults(suiteName: "fullscreen-\(UUID().uuidString)")!)
        store.update { $0.autoplay = .never }
        MediaPlaybackPolicy.store = store
        #expect(!MediaPlaybackPolicy.autoplays, "guard: grids would not autoplay")

        let pool = VideoPlaybackController(source: StubSource(), poolSize: 2, capacity: 2)
        let cell = SnapFeedCell(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        cell.configure(
            with: FeedItemDisplayModel(
                id: PostID("post-video"), authorID: ProfileID("a"), authorName: "Ava", metaText: "",
                avatarURL: nil, caption: "A clip", mediaURL: Self.clip, mediaKind: .video,
                thumbnailURL: nil, audioText: nil, likeCount: 0
            ),
            pipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            videoPlayback: pool
        )
        cell.layoutIfNeeded()
        cell.willBecomeActive()

        #expect(await settle { pool.hasPlayer(in: cell.debugRenderSurface) }, "the clip never bound")
        // Give a hold — were there one — the turn it used to take.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(pool.isPaused(in: cell.debugRenderSurface) == false, "the full-screen post was held")
        #expect(!cell.debugIsShowingPauseGlyph, "the full-screen post wears the pause mark")
    }
}
