import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Maps

/// Drives the favorites read path — repository → generated clients → real
/// ProtocolClient → MockBFF — with production wire bytes, in-process.
struct MapFavoritesRepositoryTests {
    private func makeRepository(bff: MockBFF) -> MapFavoritesRepository {
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        return MapFavoritesRepository(
            socialGraphClient: SocialGraph_V1_SocialGraphServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client)
        )
    }

    @Test func resolvesFollowedProfilesIntoTitledFavorites() async {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockSocialGraphService(dataset: dataset).register(on: bff)
        MockSocialServices(dataset: dataset, postStore: MockPostStore()).register(on: bff)

        let favorites = await makeRepository(bff: bff).following()

        // Derived from the dataset rather than pinned to a literal: the seeded
        // follow set is sized for whatever the app's screens need to show, and
        // what this test is actually about is that every followed profile
        // comes back hydrated.
        #expect(favorites.count == dataset.followedProfileIDs.count)
        #expect(Set(favorites.map(\.profileID.rawValue)) == dataset.followedProfileIDs)
        #expect(favorites.allSatisfy { !$0.title.isEmpty })
        #expect(favorites.allSatisfy { $0.avatarURL != nil })
        let titlesByID = Dictionary(uniqueKeysWithValues: favorites.map { ($0.profileID.rawValue, $0.title) })
        #expect(titlesByID["prof-0"] == "Ava Moreau")
    }

    @Test func hydratesACuratedIDListPreservingOrder() async {
        // The pinned-favorites store path: ids in, displayable people out,
        // order preserved, unresolvable ids dropped.
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockSocialGraphService(dataset: dataset).register(on: bff)
        MockSocialServices(dataset: dataset, postStore: MockPostStore()).register(on: bff)

        let favorites = await makeRepository(bff: bff).profiles(for: [
            ProfileID("prof-3"), ProfileID("prof-0"), ProfileID("prof-nope")
        ])

        #expect(favorites.map(\.title) == ["Marcus Holt", "Ava Moreau"])
    }

    @Test func friendsAreTheFollowingFollowerIntersection() async {
        // The mock graph: following = prof-0…3, followers = mutuals (0, 1)
        // + prof-4 (unrequited) — so friends must land exactly on the
        // seeded mutuals, in following order.
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockSocialGraphService(dataset: dataset).register(on: bff)
        MockSocialServices(dataset: dataset, postStore: MockPostStore()).register(on: bff)

        let friends = await makeRepository(bff: bff).friends()

        #expect(Set(friends.map(\.profileID.rawValue)) == dataset.mutualProfileIDs)
        #expect(friends.map(\.title) == ["Ava Moreau", "Kenji Tanaka"])
    }

    @Test func failsOpenToEmptyWhenSocialGraphIsUnavailable() async {
        // No routes registered → ListFollowing answers `unimplemented`; the
        // repository must resolve empty, never throw or block the map.
        let favorites = await makeRepository(bff: MockBFF()).following()
        #expect(favorites.isEmpty)
    }
}
