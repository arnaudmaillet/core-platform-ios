import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Profile

/// ⚠️ THE PEOPLE PROFILE SHOWS ARE KNOWN WHEN OPENED FROM ANYWHERE (#1858): a
/// relationship list reports every row's person; a profile read in full is
/// reported as the person itself, which replaces what rows projected.
struct ProfilePeopleSightingsTests {
    private struct Session: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> {
            AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
        }
        func logout() async {}
    }

    private final class RecordedPeople: PeopleSightings, @unchecked Sendable {
        private let lock = NSLock()
        private var sightings: [AuthorSummary] = []
        private var loads: [AuthorSummary] = []
        func saw(_ people: [AuthorSummary]) { lock.withLock { sightings += people } }
        func loaded(_ person: AuthorSummary) { lock.withLock { loads.append(person) } }
        var seen: [AuthorSummary] { lock.withLock { sightings } }
        var loaded: [AuthorSummary] { lock.withLock { loads } }
    }

    private func repositories(people: RecordedPeople) -> (ProfileRepository, ProfileRelationshipsRepository) {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        let social = MockSocialServices(dataset: dataset)
        social.register(on: bff)
        MockSocialGraphService(dataset: dataset, isPrivate: { social.isPrivate($0) }).register(on: bff)
        MockCounterService(store: MockCounterStore(dataset: dataset)).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let graph = SocialGraph_V1_SocialGraphServiceClient(client: client)
        let profiles = ProfileRepository(
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            counterClient: Counter_V1_CounterServiceClient(client: client),
            socialGraphClient: graph,
            authSession: Session(),
            people: people
        )
        let lists = ProfileRelationshipsRepository(
            socialGraphClient: graph,
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            viewer: profiles,
            supportsFollowerRemoval: true,
            people: people
        )
        return (profiles, lists)
    }

    @Test func aRelationshipListReportsItsPeople() async throws {
        let people = RecordedPeople()
        let (_, lists) = repositories(people: people)
        let viewer = ProfileID(MockSocialDataset.viewerProfileID)
        let page = try await lists.relationships(for: viewer, direction: .followers, pageToken: "", limit: 50)
        try #require(!page.relations.isEmpty)
        for row in page.relations {
            let person = try #require(people.seen.first { $0.id == row.id }, "\(row.id) not reported")
            #expect(person.handle == row.handle)
            #expect(person.avatarURL == row.avatarURL)
        }
        #expect(people.loaded.isEmpty, "a list row reported as a full profile")
    }

    @Test func aProfileReadInFullIsReportedAsThePerson() async throws {
        let people = RecordedPeople()
        let (profiles, _) = repositories(people: people)
        let id = try #require(MockSocialDataset().authors.first.map { ProfileID($0.profileID) })
        let profile = try await profiles.profile(id: id)
        let person = try #require(people.loaded.last)
        #expect(person.id == id)
        #expect(person.handle == profile.handle)
        #expect(person.displayName == profile.displayName)
        #expect(person.avatarURL == profile.avatarURL)
        #expect(person.avatarFrameID == profile.avatarFrameID)
    }
}
