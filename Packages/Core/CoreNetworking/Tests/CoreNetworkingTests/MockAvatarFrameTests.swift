import Connect
import CoreContracts
import CoreNetworkingMocks
import Foundation
import Testing
@testable import CoreNetworking

/// No author wears a frame they never bought (#1589): the mock used to hand
/// one to about an author in four, and the owner saw rainbow "Aurora" rings.
struct MockAvatarFrameTests {
    @Test func noAuthorWearsAFrame() async throws {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockSocialServices(dataset: dataset, postStore: MockPostStore()).register(on: bff)
        let client = Profile_V1_ProfileServiceClient(
            client: ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        )
        try #require(dataset.authors.count >= 12, "guard: enough authors that a 1-in-4 rule would show")
        for author in dataset.authors {
            var request = Profile_V1_GetProfileByIdRequest()
            request.profileID = author.profileID
            let view = try await client.getProfileByID(request: request, headers: [:]).result.get()
            #expect(view.avatarFrameID.isEmpty, "\(author.handle) wears \(view.avatarFrameID)")
        }
    }
}
