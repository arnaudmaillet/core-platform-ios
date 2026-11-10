import DesignSystem
import FeedInterface
import HeroPage
import PostGrid
import Testing
import UIKit
@testable import Profile

/// The profile under the flat post lists' style (#2243): which of its pages
/// are the vertical lists the style flattens, and the ground it lies on.
@MainActor
struct ProfileFlatListsTests {
    /// Posts, Reposts, Tagged (For You's list) and Short, Saved, Liked (the
    /// timeline) are vertical lists: their text posts go flat. The media
    /// mosaic is tiles and History rows, neither of which has a card to drop.
    @Test func theVerticalTabsAreTheOnesThatGoFlat() {
        let vertical: [ProfileTab] = [
            .format(.activity), .reposts, .tagged, .format(.short), .saved, .reactions,
        ]
        for tab in vertical {
            let style = ProfileGalleryPagerView.style(for: tab)
            #expect(style == .discover || style == .list, "\(tab) is not a vertical list")
        }
        #expect(ProfileGalleryPagerView.style(for: .format(.media)) == .grid)
        #expect(ProfileGalleryPagerView.style(for: .history) == .rows)
    }

    /// The profile is a hero page: it lies on the list style's ground — the
    /// grey page under cards, the white one under flat rows — and its
    /// banner melts into the same tone.
    @Test func theProfileLiesOnTheListStylesGround() {
        #expect(HeroPageGround.color == PostListStyle.current.pageGround)
    }
}
