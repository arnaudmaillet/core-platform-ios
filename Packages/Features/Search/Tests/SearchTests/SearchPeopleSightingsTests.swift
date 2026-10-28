import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Search

/// ⚠️ A PERSON A SEARCH SHOWS IS KNOWN THE NEXT TIME THEY ARE OPENED (#1858):
/// the profile the row's metadata read for its avatar is reported in full.
struct SearchPeopleSightingsTests {
    private final class RecordedPeople: PeopleSightings, @unchecked Sendable {
        private let lock = NSLock()
        private var sightings: [AuthorSummary] = []
        func saw(_ people: [AuthorSummary]) { lock.withLock { sightings += people } }
        func loaded(_ person: AuthorSummary) { lock.withLock { sightings.append(person) } }
        var seen: [AuthorSummary] { lock.withLock { sightings } }
    }

    @Test func theRowsMetadataReportsThePerson() async throws {
        let dataset = MockSocialDataset()
        let author = try #require(dataset.authors.first)
        let bff = MockBFF()
        MockSocialServices(dataset: dataset).register(on: bff)
        MockSocialGraphService(dataset: dataset).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let people = RecordedPeople()
        let repository = ProfileMetadataRepository(
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            socialGraphClient: SocialGraph_V1_SocialGraphServiceClient(client: client),
            viewerID: { nil },
            people: people
        )
        let id = ProfileID(author.profileID)
        let metadata = await repository.metadata(for: [id])
        let person = try #require(people.seen.first { $0.id == id }, "the person was not reported")
        #expect(person.handle == author.handle)
        #expect(!person.displayName.isEmpty)
        #expect(person.avatarURL == metadata[id]?.avatarURL)
    }
}
