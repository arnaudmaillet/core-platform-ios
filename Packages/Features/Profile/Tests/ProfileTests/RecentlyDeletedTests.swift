import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import PostGrid
import Testing
@testable import Profile

/// Deleting a post of one's own, and Recently Deleted (#408, backend #663),
/// end to end over the mock BFF.
@MainActor
struct RecentlyDeletedTests {
    private struct Session: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> {
            AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
        }
        func logout() async {}
    }

    private struct Fixture {
        let social: MockSocialServices
        let gallery: ProfileGalleryRepository
        let profiles: ProfileRepository
    }

    private func makeFixture() -> Fixture {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        let social = MockSocialServices(dataset: dataset)
        social.register(on: bff)
        MockSocialGraphService(dataset: dataset).register(on: bff)
        let counters = MockCounterStore(dataset: dataset)
        MockCounterService(store: counters).register(on: bff)
        MockSearchService(dataset: dataset, counters: counters).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let gallery = ProfileGalleryRepository(
            postClient: Post_V1_PostServiceClient(client: client),
            searchClient: Search_V1_SearchServiceClient(client: client),
            counterClient: Counter_V1_CounterServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client)
        )
        let profiles = ProfileRepository(
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            counterClient: Counter_V1_CounterServiceClient(client: client),
            socialGraphClient: SocialGraph_V1_SocialGraphServiceClient(client: client),
            authSession: Session()
        )
        return Fixture(social: social, gallery: gallery, profiles: profiles)
    }

    private let viewer = ProfileID(MockSocialDataset.viewerProfileID)

    /// Done when: a deleted post can be restored within 30 days. It leaves the
    /// profile, waits in Recently Deleted, and comes back where it was.
    @Test func aDeletedPostComesBack() async throws {
        let fixture = makeFixture()
        let before = try await fixture.gallery.authoredPosts(for: viewer)
        let post = try #require(before.first)

        try await fixture.gallery.deletePost(post.id, author: viewer)
        #expect(try await !fixture.gallery.authoredPosts(for: viewer).map(\.id).contains(post.id))
        let trash = try await fixture.gallery.recentlyDeleted(for: viewer)
        #expect(trash.map(\.post.id) == [post.id])
        #expect(trash.first?.deletedAt != nil)
        #expect(trash.first?.daysLeft() == 30)

        try await fixture.gallery.restorePost(post.id, author: viewer)
        #expect(try await fixture.gallery.authoredPosts(for: viewer).map(\.id) == before.map(\.id))
        #expect(try await fixture.gallery.recentlyDeleted(for: viewer).isEmpty)
        await #expect(throws: PostRestoreError.notDeleted) {
            try await fixture.gallery.restorePost(post.id, author: viewer)
        }
    }

    /// Only the author deletes, and after 30 days a post stays gone.
    @Test func onlyTheAuthorAndOnlyWithin30Days() async throws {
        let fixture = makeFixture()
        let post = try #require(try await fixture.gallery.authoredPosts(for: viewer).first)
        await #expect(throws: (any Error).self) {
            try await fixture.gallery.deletePost(post.id, author: ProfileID("prof-3"))
        }

        try await fixture.gallery.deletePost(post.id, author: viewer)
        fixture.social.backdateDeletion(of: post.id.rawValue, by: 31 * 86_400)
        #expect(try await fixture.gallery.recentlyDeleted(for: viewer).isEmpty)
        await #expect(throws: PostRestoreError.tooLate) {
            try await fixture.gallery.restorePost(post.id, author: viewer)
        }
    }

    /// The screen restores and drops the row; the row names the post and
    /// the days left.
    @Test func theScreenRestores() async throws {
        let fixture = makeFixture()
        let post = try #require(try await fixture.gallery.authoredPosts(for: viewer).first)
        try await fixture.gallery.deletePost(post.id, author: viewer)

        let viewModel = RecentlyDeletedViewModel(trash: fixture.gallery, viewer: fixture.profiles)
        await viewModel.load()
        guard case .loaded(let posts) = viewModel.phase, let deleted = posts.first else {
            Issue.record("the list didn't load")
            return
        }
        #expect(RecentlyDeletedViewModel.remaining(deleted) == "30 days left")
        try await viewModel.restore(deleted)
        #expect(viewModel.phase == .loaded([]))
    }

    /// A window that crosses the end of daylight saving still starts at 30
    /// days: Paris, deleted at 00:30 on 6 October, the clocks go back on
    /// 25 October.
    @Test func theWindowSurvivesTheClockChange() throws {
        var paris = Calendar(identifier: .gregorian)
        paris.timeZone = try #require(TimeZone(identifier: "Europe/Paris"))
        let deletedAt = try #require(paris.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 0, minute: 30)))
        let text = GalleryPost(id: PostID("p"), kind: .text, isRepost: false, thumbnailURL: nil, caption: "", publishedAtMS: 0)
        let deleted = DeletedPost(post: text, deletedAt: deletedAt)
        #expect(deleted.daysLeft(now: deletedAt, calendar: paris) == 30)
        #expect(deleted.daysLeft(now: deletedAt.addingTimeInterval(29 * 86_400), calendar: paris) == 1)
        // And the other way, into daylight saving (29 March 2026).
        let spring = try #require(paris.date(from: DateComponents(year: 2026, month: 3, day: 20, hour: 23, minute: 30)))
        #expect(DeletedPost(post: text, deletedAt: spring).daysLeft(now: spring, calendar: paris) == 30)
    }

    @Test func theRowsReadPlainly() {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let calendar = Calendar(identifier: .gregorian)
        let text = GalleryPost(id: PostID("p"), kind: .text, isRepost: false, thumbnailURL: nil, caption: "  ", publishedAtMS: 0)
        let deleted = DeletedPost(post: text, deletedAt: day)
        #expect(RecentlyDeletedViewModel.title(of: deleted) == "Post")
        let coded = GalleryPost(id: PostID("q"), kind: .text, isRepost: false, thumbnailURL: nil, caption: "Shipped :lmao:", publishedAtMS: 0)
        #expect(!RecentlyDeletedViewModel.title(of: DeletedPost(post: coded, deletedAt: day)).contains(":lmao:"))
        #expect(RecentlyDeletedViewModel.remaining(deleted, now: day.addingTimeInterval(29 * 86_400), calendar: calendar) == "1 day left")
        #expect(RecentlyDeletedViewModel.remaining(deleted, now: day.addingTimeInterval(30 * 86_400), calendar: calendar) == "Last day")
        #expect(RecentlyDeletedViewController.footer.contains("30 days"))
        #expect(ProfileViewController.deletePostMessage.contains("Recently Deleted"))
    }
}
