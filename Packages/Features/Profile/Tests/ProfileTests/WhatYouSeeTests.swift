import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Profile

/// Settings → What You See (#407, #413; backend #731, timeline #662):
/// sensitive content, Personalised For You, the interests that rank it, and
/// how the feeds are ordered.
@MainActor
struct WhatYouSeeTests {
    private struct Session: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> {
            AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
        }
        func logout() async {}
    }

    private func makeRepository() -> ProfileRepository {
        makeFixture().repository
    }

    private func makeFixture() -> (repository: ProfileRepository, interests: InterestTagsRepository) {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockSocialServices(dataset: dataset).register(on: bff)
        MockSocialGraphService(dataset: dataset).register(on: bff)
        MockCounterService(store: MockCounterStore(dataset: dataset)).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let repository = ProfileRepository(
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            counterClient: Counter_V1_CounterServiceClient(client: client),
            socialGraphClient: SocialGraph_V1_SocialGraphServiceClient(client: client),
            authSession: Session()
        )
        return (repository, InterestTagsRepository(timelineClient: Timeline_V1_TimelineServiceClient(client: client), profiles: repository))
    }

    /// Less by default; Standard sticks, and it's per profile.
    @Test func sensitiveContentRoundTripsPerProfile() async throws {
        let repository = makeRepository()
        #expect(try await repository.sensitiveContent() == .less)
        try await repository.setSensitiveContent(.standard)
        #expect(try await repository.sensitiveContent() == .standard)

        let profiles = try await repository.accountProfiles()
        await repository.setActiveProfile(profiles[1].id)
        #expect(try await repository.sensitiveContent() == .less, "another profile keeps its own")
        try await repository.setSensitiveContent(.standard)
        try await repository.setSensitiveContent(.less)
        #expect(try await repository.sensitiveContent() == .less)
    }

    /// Both settings share one FeedSettings that SetFeedSettings replaces
    /// whole: changing one keeps the other.
    @Test func personalisationAndSensitiveContentKeepEachOther() async throws {
        let repository = makeRepository()
        #expect(try await repository.personalizedFeed(), "on by default for an adult")
        try await repository.setSensitiveContent(.standard)
        try await repository.setPersonalizedFeed(false)
        #expect(try await repository.sensitiveContent() == .standard, "turning personalisation off kept Standard")
        try await repository.setSensitiveContent(.less)
        #expect(try await !repository.personalizedFeed(), "changing the level kept personalisation off")
        try await repository.setPersonalizedFeed(true)
        #expect(try await repository.personalizedFeed())
        #expect(try await repository.sensitiveContent() == .less)
    }

    /// The interests are listed heaviest first; one can be removed, and a
    /// reset forgets them all.
    @Test func interestsCanBeRemovedOneByOneOrReset() async throws {
        let (_, interests) = makeFixture()
        let listed = try await interests.interests()
        #expect(listed.map(\.tag) == MockSocialServices.seededInterests.map(\.tag))
        #expect(listed.map(\.weight) == listed.map(\.weight).sorted(by: >))

        let remaining = try await interests.removeInterest("foodie")
        #expect(!remaining.map(\.tag).contains("foodie"))
        #expect(remaining.count == listed.count - 1)
        #expect(try await interests.interests() == remaining)

        #expect(try await interests.resetInterests().isEmpty)
        #expect(try await interests.interests().isEmpty)
    }

    /// Turning Personalised For You off erases what was learnt (timeline
    /// #662), which is why the screen reads the list again.
    @Test func turningPersonalisationOffErasesInterests() async throws {
        let (repository, interests) = makeFixture()
        #expect(try await !interests.interests().isEmpty)
        try await repository.setPersonalizedFeed(false)
        #expect(try await interests.interests().isEmpty)
    }

    @Test func theScreenSaysHowTheFeedsAreOrdered() {
        #expect(SensitiveContentLevel.allCases.map(\.title) == ["Less", "Standard"])
        #expect(SensitiveContentLevel.standard.detail.contains("under 18"))
        // Done when: the chronological option shows followed posts newest first.
        #expect(WhatYouSeeViewController.followingDetail.contains("newest first"))
        #expect(WhatYouSeeViewController.forYouDetail(personalized: false).contains("same way for everyone"))
        #expect(WhatYouSeeViewController.forYouDetail(personalized: true).contains("match your interests"))
        #expect(WhatYouSeeViewController.footer(.sensitive, teen: true)?.contains("under 18") == true)
        #expect(WhatYouSeeViewController.footer(.interests, teen: false)?.contains("Swipe left") == true)
        #expect(WhatYouSeeViewController.strength(0.92) == "Strong")
        #expect(WhatYouSeeViewController.strength(0.44) == "Moderate")
        #expect(WhatYouSeeViewController.strength(0.18) == "Light")
    }
}
