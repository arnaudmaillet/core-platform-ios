import Feed
import FeedInterface
import Foundation
import MediaCore
import MediaPlayback
@testable import Profile

/// The profile's pages are For You's grid (#1273): the suites draw the
/// profile on the real page, built the way the composition root builds it.
@MainActor
enum TestGridPages {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    /// For You's page, with its own silent pipeline and `videoPlayback`'s
    /// pool when a suite has one.
    static func factory(
        imagePipeline: ImagePipeline? = nil, videoPlayback: VideoPlaybackController? = nil
    ) -> ProfileGridPageFactory {
        let pipeline = imagePipeline ?? ImagePipeline(fetcher: SilentFetcher())
        return { style, savesPosts in
            PostGridPages.make(
                style: style, imagePipeline: pipeline, videoPlayback: videoPlayback, savesPosts: savesPosts
            )
        }
    }

    /// The pager's maker, which takes the style alone.
    static func pageMaker(
        imagePipeline: ImagePipeline? = nil, videoPlayback: VideoPlaybackController? = nil,
        savesPosts: Bool = false
    ) -> (PostGridPageStyle) -> any PostGridPage {
        let make = factory(imagePipeline: imagePipeline, videoPlayback: videoPlayback)
        return { make($0, savesPosts) }
    }
}
