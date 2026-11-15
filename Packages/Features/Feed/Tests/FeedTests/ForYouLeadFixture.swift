import CoreModels
import Foundation
import MediaCore
import MediaPlayback
import PostGrid
import UIKit
@testable import Feed

/// A shelf leading a grid, as the place page and a post set assemble it
/// (#1271): the Following shelf stacked over a titled list — the real views.
/// The Friends row that led it on For You went with the tab (#2453).
@MainActor
final class ForYouLeadFixture {
    let shelf: PostShelfSection
    let stack: GridLeadStack

    init(
        pipeline: ImagePipeline = ImagePipeline(fetcher: PlaceholderImageFetcher()),
        videoPlayback: VideoPlaybackController? = nil,
        width: CGFloat = 393
    ) {
        shelf = PostShelfSection(imagePipeline: pipeline, videoPlayback: videoPlayback)
        stack = GridLeadStack(sections: [shelf])
        shelf.title = "Following"
        stack.listTitle = "For you"
        stack.frame = CGRect(x: 0, y: 0, width: width, height: 600)
    }

    /// The shelf's cards and the count on its header.
    func render(following: [GalleryPost], newCount: Int = 0) {
        shelf.setCount(new: newCount)
        shelf.render(following)
        stack.setNeedsLayout()
    }

    /// Puts back everything a flight hid.
    func clearConcealments() {
        shelf.clearConcealments()
    }

    /// Sizes the lead to what it holds and lays it out.
    func layout() {
        stack.frame.size.height = max(1, stack.preferredHeight(forWidth: stack.bounds.width))
        stack.layoutIfNeeded()
    }

    /// The lead's height for `following` cards (of which `textCards` are
    /// text) at `width`.
    static func height(forWidth width: CGFloat, following: Int, textCards: Int = 0) -> CGFloat {
        GridLeadStack.height(sections: [
            PostShelfSection.height(forWidth: width, media: following - textCards, text: textCards),
        ])
    }
}
