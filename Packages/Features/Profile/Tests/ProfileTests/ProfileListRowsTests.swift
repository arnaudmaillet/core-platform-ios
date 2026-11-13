import CoreModels
import DesignSystem
import FeedInterface
import HeroPage
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Profile
@testable import ProfileSettings

/// The profile's post lists (#2243; the only style since #2290): which of its
/// pages are the vertical lists whose text posts are rows, the ground it
/// lies on, and the hairline closing its header (#2289).
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

    /// ⚠️ THE HEADER CLOSES WITH THE POSTS' HAIRLINE (#2289): the profile's
    /// header draws it, over every tab, where a header built for another
    /// screen (the profile card's sheet) draws none.
    @Test func theProfilesHeaderClosesWithTheHairline() {
        let pipeline = ImagePipeline(fetcher: PlaceholderImageFetcher())
        let screen = ProfileViewController(
            viewModel: ProfileViewModel(repository: NoProfiles()),
            imagePipeline: pipeline,
            makeGridPage: TestGridPages.factory(),
            onLogout: nil
        )
        screen.loadViewIfNeeded()
        #expect(screen.headerView.drawsFootHairline)
        #expect(!ProfileHeaderView(imagePipeline: pipeline).drawsFootHairline, "on by default")
    }
}

/// No profile behind it: the header only has to be built.
private struct NoProfiles: ProfileProviding {
    func currentUserProfile() async throws -> UserProfile { throw CancellationError() }
    func profile(id: ProfileID) async throws -> UserProfile { throw CancellationError() }
    func relationship(for profileID: ProfileID) async throws -> ProfileRelationship { .me }
    func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {}
    func setBlocked(_ blocked: Bool, for profileID: ProfileID) async throws {}
    func blockAccount(behind profileID: ProfileID) async throws -> [ProfileID] { [] }
    func updateCurrentUserProfile(
        displayName: String, bio: String, website: String, links: [ProfileLink]
    ) async throws -> UserProfile { throw CancellationError() }
    func changeHandle(_ newHandle: String) async throws -> UserProfile { throw CancellationError() }
}
