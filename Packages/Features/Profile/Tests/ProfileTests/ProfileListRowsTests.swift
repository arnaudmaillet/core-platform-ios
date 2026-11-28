import CoreModels
import CoreStorage
import DesignSystem
import FeedInterface
import HeroPage
import MediaCore
import MediaCoreFixtures
import PostGrid
import Testing
import UIKit
@testable import Profile
@testable import ProfileData

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

    /// ⚠️ NO HAIRLINE UNDER THE PROFILE'S HEADER (the owner, 2026-11-28,
    /// revising #2289 for the profile): the selector, on glass, closes the
    /// header; nothing draws a line under it.
    @Test func theProfilesHeaderDrawsNoHairline() {
        let pipeline = ImagePipeline(fetcher: PlaceholderImageFetcher())
        let screen = ProfileViewController(
            viewModel: ProfileViewModel(repository: NoProfiles()),
            imagePipeline: pipeline,
            makeGridPage: TestGridPages.factory(), presence: SectionPresenceStore(scope: StorageScope()),
            onLogout: nil
        )
        screen.loadViewIfNeeded()
        #expect(!screen.headerView.drawsFootHairline, "a line under the profile's selector")
    }

    /// ⚠️ NO FOLLOW ON A PROFILE'S POST LISTS (#2419, the owner 2026-11-28):
    /// the header's Follow is the one (#2248, #2302). Every page the profile
    /// builds — its tabs and its media gallery, the same factory — offers no
    /// author Follow on its bands, while the same page built for another
    /// host does.
    @Test func theProfilesListsOfferNoAuthorFollow() throws {
        let pipeline = ImagePipeline(fetcher: PlaceholderImageFetcher())
        let factory = TestGridPages.factory(imagePipeline: pipeline)
        #expect(factory(.list, false).offersAuthorFollow, "another host's list lost its Follow")
        let screen = ProfileViewController(
            viewModel: ProfileViewModel(repository: NoProfiles()),
            imagePipeline: pipeline,
            makeGridPage: factory, presence: SectionPresenceStore(scope: StorageScope()),
            onLogout: nil
        )
        screen.loadViewIfNeeded()
        for style in [PostGridPageStyle.list, .discover, .grid, .rows] {
            #expect(!screen.makeGridPage(style, false).offersAuthorFollow, "\(style) offers the band's Follow")
            #expect(!screen.makeGridPage(style, true).offersAuthorFollow, "\(style) (saves) offers the band's Follow")
        }
        let posts = try #require(screen.galleryPager.builtPage(for: .format(.activity)), "Posts was not built")
        #expect(!posts.offersAuthorFollow, "the Posts tab offers the band's Follow")
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
