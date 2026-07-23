import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Maps

/// The multi-selection read path end to end — repository → generated client →
/// real ProtocolClient → MockBFF → `MockGeoDiscoveryService` — with the
/// production wire bytes and the production header.
///
/// This is the test that actually pins down "Lena AND Marcus": the union's
/// pin set must be exactly the two singles put together, not one of them and
/// not everything.
struct MultiSelectQueryTests {
    private static let paris = MapViewport.make(
        centerLat: 48.8566, centerLng: 2.3522, latitudeSpan: 0.6, longitudeSpan: 0.6
    )

    private func makeRepository() -> GeoDiscoveryRepository {
        let bff = MockBFF()
        MockGeoDiscoveryService(dataset: MockSocialDataset()).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        return GeoDiscoveryRepository(geoClient: GeoDiscovery_V1_GeoDiscoveryServiceClient(client: client))
    }

    private func postIDs(_ filter: MapFilter?) async throws -> Set<PostID> {
        let result = try await makeRepository().queryTile(Self.paris, filter: filter)
        return Set(result.pins.map(\.postID))
    }

    @Test func unionQueryReturnsExactlyBothAuthorsPins() async throws {
        let authors = MockSocialDataset().authors
        let first = MapFilter.profile(ProfileID(authors[0].profileID))
        let second = MapFilter.profile(ProfileID(authors[1].profileID))

        let firstPins = try await postIDs(first)
        let secondPins = try await postIDs(second)
        let unionPins = try await postIDs(MapFilter.resolved([first, second]))

        #expect(!firstPins.isEmpty)
        #expect(!secondPins.isEmpty)
        #expect(firstPins.isDisjoint(with: secondPins))
        #expect(unionPins == firstPins.union(secondPins))
    }

    @Test func unionOfCategoriesMatchesEitherCategory() async throws {
        let cafes = MapFilter.pinnedCategory("cafes")
        let parks = MapFilter.pinnedCategory("parks")

        let cafePins = try await postIDs(cafes)
        let parkPins = try await postIDs(parks)
        let unionPins = try await postIDs(MapFilter.resolved([cafes, parks]))

        #expect(!cafePins.isEmpty)
        #expect(!parkPins.isEmpty)
        #expect(unionPins == cafePins.union(parkPins))
    }

    @Test func aSingleSelectionIsUnchangedByTheMultiPath() async throws {
        // `resolved` on one member must produce the same query as before —
        // multi-selection is not allowed to perturb the common case.
        let lena = MapFilter.profile(ProfileID(MockSocialDataset().authors[2].profileID))
        #expect(try await postIDs(lena) == (try await postIDs(MapFilter.resolved([lena]))))
    }
}
