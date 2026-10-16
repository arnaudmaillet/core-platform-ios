import CoreModels
import Foundation
import MediaCore
import MediaPlayback
import UIKit
@testable import Feed

/// For You's lead as `ForYouViewController` assembles it (#1271): the
/// Friends row and the Following shelf, stacked over "For you" — the real
/// three views, rendered from the view model's rows the way the screen does
/// (`ForYouViewController.renderLead`).
@MainActor
final class ForYouLeadFixture {
    let friends: FriendsStoriesRow
    let shelf: PostShelfSection
    let stack: GridLeadStack

    init(
        pipeline: ImagePipeline = ImagePipeline(fetcher: PlaceholderImageFetcher()),
        videoPlayback: VideoPlaybackController? = nil,
        width: CGFloat = 393
    ) {
        friends = FriendsStoriesRow(imagePipeline: pipeline)
        shelf = PostShelfSection(imagePipeline: pipeline, videoPlayback: videoPlayback)
        stack = GridLeadStack(sections: [friends, shelf])
        shelf.title = "Following"
        stack.listTitle = "For you"
        stack.frame = CGRect(x: 0, y: 0, width: width, height: 600)
    }

    func render(_ rows: ForYouViewModel.Rails) {
        friends.render(rows.friends, newCount: rows.friendsBadge)
        shelf.setCount(new: rows.followingBadge)
        shelf.render(rows.following)
        stack.setNeedsLayout()
    }

    /// Puts back everything a flight hid, in both rows.
    func clearConcealments() {
        friends.clearConcealments()
        shelf.clearConcealments()
    }

    /// Sizes the lead to what it holds and lays it out.
    func layout() {
        stack.frame.size.height = max(1, stack.preferredHeight(forWidth: stack.bounds.width))
        stack.layoutIfNeeded()
    }

    /// The lead's height for `friends` faces and `following` cards (of
    /// which `textCards` are text) at `width`.
    static func height(forWidth width: CGFloat, friends: Int, following: Int, textCards: Int = 0) -> CGFloat {
        GridLeadStack.height(sections: [
            FriendsStoriesRow.height(forWidth: width, friends: friends),
            PostShelfSection.height(forWidth: width, media: following - textCards, text: textCards),
        ])
    }
}
