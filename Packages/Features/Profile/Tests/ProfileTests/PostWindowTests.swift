import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import PostGrid
import Testing
@testable import Profile

/// Settings → Privacy → Posts Visible to Others (#411, backend #729), end to
/// end over the mock BFF.
@MainActor
struct PostWindowTests {
    private struct Session: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> {
            AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
        }
        func logout() async {}
    }

    private struct Fixture {
        let profiles: ProfileRepository
        let gallery: ProfileGalleryRepository
        let profileClient: Profile_V1_ProfileServiceClient
    }

    private func makeFixture() -> Fixture {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockSocialServices(dataset: dataset).register(on: bff)
        MockSocialGraphService(dataset: dataset).register(on: bff)
        let counters = MockCounterStore(dataset: dataset)
        MockCounterService(store: counters).register(on: bff)
        MockSearchService(dataset: dataset, counters: counters).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let profileClient = Profile_V1_ProfileServiceClient(client: client)
        return Fixture(
            profiles: ProfileRepository(
                profileClient: profileClient,
                counterClient: Counter_V1_CounterServiceClient(client: client),
                socialGraphClient: SocialGraph_V1_SocialGraphServiceClient(client: client),
                authSession: Session()
            ),
            gallery: ProfileGalleryRepository(
                postClient: Post_V1_PostServiceClient(client: client),
                searchClient: Search_V1_SearchServiceClient(client: client),
                counterClient: Counter_V1_CounterServiceClient(client: client),
                profileClient: profileClient
            ),
            profileClient: profileClient
        )
    }

    /// All by default; a change sticks.
    @Test func theWindowRoundTrips() async throws {
        let fixture = makeFixture()
        #expect(try await fixture.profiles.postWindow() == .all)
        try await fixture.profiles.setPostWindow(.oneMonth)
        #expect(try await fixture.profiles.postWindow() == .oneMonth)
        try await fixture.profiles.setPostWindow(.all)
        #expect(try await fixture.profiles.postWindow() == .all)
    }

    /// Done when: older posts disappear for visitors without being deleted.
    /// Another author's one-month window hides their older posts from the
    /// viewer; widening it brings them back.
    @Test func olderPostsDisappearForVisitorsAndComeBack() async throws {
        let fixture = makeFixture()
        let author = ProfileID("prof-3")
        let everything = try await fixture.gallery.authoredPosts(for: author)
        #expect(!everything.isEmpty)

        var narrow = Profile_V1_SetTabSettingsRequest()
        narrow.profileID = author.rawValue
        narrow.postWindow = .oneMonth
        _ = try await fixture.profileClient.setTabSettings(request: narrow, headers: [:]).result.get()

        let monthAgoMS = Int64((Date().timeIntervalSince1970 - 30 * 86_400) * 1_000)
        let windowed = try await fixture.gallery.authoredPosts(for: author)
        #expect(windowed.allSatisfy { $0.publishedAtMS >= monthAgoMS })
        #expect(windowed.count < everything.count, "the seed has posts older than a month")

        var wide = narrow
        wide.postWindow = .all
        _ = try await fixture.profileClient.setTabSettings(request: wide, headers: [:]).result.get()
        #expect(try await fixture.gallery.authoredPosts(for: author).map(\.id) == everything.map(\.id))
    }

    /// The owner always sees all of their own posts.
    @Test func theOwnerSeesEverything() async throws {
        let fixture = makeFixture()
        let viewer = ProfileID(MockSocialDataset.viewerProfileID)
        let before = try await fixture.gallery.authoredPosts(for: viewer)
        try await fixture.profiles.setPostWindow(.threeDays)
        #expect(try await fixture.gallery.authoredPosts(for: viewer).map(\.id) == before.map(\.id))
    }

    @Test func theChoicesReadPlainly() {
        #expect(PostWindow.allCases.map(\.title) == ["All Posts", "Last 6 Months", "Last Month", "Last 3 Days"])
    }
}
