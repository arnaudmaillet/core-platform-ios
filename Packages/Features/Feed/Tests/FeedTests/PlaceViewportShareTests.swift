import CoreModels
import CoreNavigation
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// The place page under a plain screen pushed over it (#1914): its clips play
/// while it holds half the viewport, pause below, and come back at half on the
/// way back — the rule of every covered screen (`ViewportShare`).
@MainActor
struct PlaceViewportShareTests {
    private func screen() -> PlaceProfileViewController {
        let post = GalleryPost(
            id: PostID("p1"), kind: .photo, isRepost: false, thumbnailURL: nil,
            caption: "", publishedAtMS: 0, reactionCount: 3
        )
        let screen = PlaceProfileViewController(
            postIDs: [post.id], placeName: "Paris • City Cluster",
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()), videoPlayback: nil,
            loadPosts: { [post] }, openPost: { _, _, _ in }
        )
        screen.loadViewIfNeeded()
        return screen
    }

    /// The gate reads the share: half and above plays, below pauses.
    @Test func thePagePlaysAtHalfAndAbove() {
        let screen = screen()
        #expect(screen.debugAutoplayIsActive)
        screen.debugViewportShare.report(0.6)
        #expect(screen.debugAutoplayIsActive, "the page paused above half")
        screen.debugViewportShare.report(0.4)
        #expect(!screen.debugAutoplayIsActive, "the page plays on under a screen past half")
        screen.debugViewportShare.report(0.5)
        #expect(screen.debugAutoplayIsActive, "the page did not come back at half")
    }

    /// No transition to follow (a tab switch): stopped at once, and back at
    /// once, as before.
    @Test func aTabSwitchStopsAndRestartsAtOnce() {
        let screen = screen()
        screen.beginAppearanceTransition(false, animated: false)
        screen.endAppearanceTransition()
        #expect(!screen.debugAutoplayIsActive)
        screen.beginAppearanceTransition(true, animated: false)
        screen.endAppearanceTransition()
        #expect(screen.debugAutoplayIsActive)
    }
}
