import DesignSystem
import FeedInterface
import HeroPage
import PostGrid
import Testing
import UIKit
@testable import Profile

/// The profile's post lists (#2243; the only style since #2290): which of its
/// pages are the vertical lists whose text posts are rows, and the ground it
/// lies on.
@MainActor
struct ProfileListRowsTests {
    /// Posts, Reposts, Tagged (For You's list) and Short, Saved, Liked (the
    /// timeline) are vertical lists: their text posts are rows. The media
    /// mosaic is tiles and History rows, neither of which is a list row.
    @Test func theVerticalTabsAreTheOnesThatDrawRows() {
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

    /// The profile is a hero page: it lies on the plain page, and its banner
    /// melts into the same tone.
    @Test func theProfileLiesOnThePlainPage() {
        #expect(HeroPageGround.color == Surface.plainPage)
    }
}
