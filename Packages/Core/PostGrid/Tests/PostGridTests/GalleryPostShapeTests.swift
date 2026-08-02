import CoreModels
import Foundation
import Testing
@testable import PostGrid

struct GalleryPostShapeTests {
    private func post(
        kind: GalleryPost.Kind = .video,
        aspect: Double,
        videoURL: URL? = URL(string: "mock://video/1")
    ) -> GalleryPost {
        GalleryPost(
            id: PostID("p"), kind: kind, isRepost: false, thumbnailURL: nil,
            videoURL: videoURL, aspectRatio: aspect, caption: "", publishedAtMS: 0
        )
    }

    // MARK: - Classification

    @Test func portraitRatiosClassifyAsPortrait() {
        #expect(post(aspect: 1080.0 / 1920).shape == .portrait) // 9:16, 0.5625
        #expect(post(aspect: 0.5).shape == .portrait)           // 1:2
        #expect(post(aspect: 1080.0 / 1350).shape == .portrait) // 4:5, 0.8
    }

    @Test func landscapeRatiosClassifyAsLandscape() {
        #expect(post(aspect: 2.0).shape == .landscape)          // 2:1
        #expect(post(aspect: 1680.0 / 750).shape == .landscape) // 2.24
        #expect(post(aspect: 1920.0 / 1080).shape == .landscape) // 16:9, 1.78
    }

    @Test func squareRatiosClassifyAsSquare() {
        #expect(post(aspect: 1.0).shape == .square)
        #expect(post(aspect: 1080.0 / 1080).shape == .square)
    }

    /// The tolerance exists so a re-encode that lands a hair off 1:1 is still
    /// square, without swallowing 4:5 and 5:4 crops.
    @Test func nearSquareRatiosStaySquareButRealCropsDoNot() {
        #expect(post(aspect: 1.05).shape == .square)
        #expect(post(aspect: 0.95).shape == .square)
        #expect(post(aspect: 0.8).shape == .portrait)  // 4:5
        #expect(post(aspect: 1.25).shape == .landscape) // 5:4
    }

    // MARK: - Autoplay rule

    @Test func portraitAndLandscapeVideosAutoplay() {
        #expect(post(aspect: 0.5625).autoplaysInGrid)
        #expect(post(aspect: 2.24).autoplaysInGrid)
    }

    /// The explicit requirement: square video tiles stay still.
    @Test func squareVideosDoNotAutoplay() {
        #expect(!post(aspect: 1.0).autoplaysInGrid)
        #expect(!post(aspect: 960.0 / 960).autoplaysInGrid)
    }

    @Test func nonVideoPostsNeverAutoplay() {
        #expect(!post(kind: .photo, aspect: 0.5).autoplaysInGrid)
        #expect(!post(kind: .text, aspect: 2.0).autoplaysInGrid)
    }

    @Test func aVideoWithoutAStreamCannotAutoplay() {
        #expect(!post(aspect: 0.5, videoURL: nil).autoplaysInGrid)
    }

    /// Unknown dimensions arrive as 1.0 from `MediaAttachment.aspectRatio`, so
    /// they read as square and withhold autoplay rather than guessing. Documents
    /// the fail-closed direction — see `BACKEND_MEDIA_ASPECT_RATIO_SUPPORT.md`.
    @Test func unknownDimensionsWithholdAutoplay() {
        let unknown = GalleryPost(
            id: PostID("p"), kind: .video, isRepost: false, thumbnailURL: nil,
            videoURL: URL(string: "mock://video/1"), caption: "", publishedAtMS: 0
        )
        #expect(unknown.aspectRatio == 1)
        #expect(unknown.shape == .square)
        #expect(!unknown.autoplaysInGrid)
    }

    @Test func nonPositiveAspectIsTreatedAsSquare() {
        #expect(post(aspect: 0).shape == .square)
        #expect(post(aspect: -3).shape == .square)
    }
}
