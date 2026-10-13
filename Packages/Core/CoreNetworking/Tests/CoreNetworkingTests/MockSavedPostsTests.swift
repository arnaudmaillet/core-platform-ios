import Connect
import CoreContracts
import CoreNetworkingMocks
import Foundation
import Testing
@testable import CoreNetworking

private struct MemberToken: AuthTokenProviding {
    func validAccessToken() async throws -> String? { "at-1" }
}

/// The mock's saves (#837): engagement's SavePost / UnsavePost /
/// ListSavedPosts with the backend's rules.
struct MockSavedPostsTests {
    private let dataset = MockSocialDataset()
    private let profile = MockSocialDataset.viewerProfileID

    private func make() -> Engagement_V1_EngagementServiceClient {
        let bff = MockBFF()
        MockEngagementService(store: MockCounterStore(dataset: dataset), dataset: dataset).register(on: bff)
        let client = ConnectClientFactory.makeAuthenticated(
            host: "https://mock.bff.local", tokenProvider: MemberToken(), httpClient: bff
        )
        return Engagement_V1_EngagementServiceClient(client: client)
    }

    private func save(_ client: Engagement_V1_EngagementServiceClient, _ post: String, account: String = MockAuthService.accountID) async -> ConnectError? {
        var request = Engagement_V1_SavePostRequest()
        request.accountID = account
        request.profileID = profile
        request.postID = post
        return await client.savePost(request: request, headers: [:]).error
    }

    private func list(_ client: Engagement_V1_EngagementServiceClient, limit: Int32 = 0) async throws -> [String] {
        var ids: [String] = []
        var token = ""
        repeat {
            var request = Engagement_V1_ListSavedPostsRequest()
            request.profileID = profile
            request.limit = limit
            request.pageToken = token
            let page = try #require(await client.listSavedPosts(request: request, headers: [:]).message)
            ids += page.posts.map(\.postID)
            token = page.nextPageToken
        } while !token.isEmpty
        return ids
    }

    @Test func savesListMostRecentFirstAcrossPages() async throws {
        let client = make()
        for post in ["p1", "p2", "p3"] { #expect(await save(client, post) == nil) }
        // A re-save keeps its first place.
        #expect(await save(client, "p1") == nil)

        #expect(try await list(client, limit: 2) == ["p3", "p2", "p1"])
    }

    @Test func anUnsaveLeavesTheListAndTwiceIsANoOp() async throws {
        let client = make()
        _ = await save(client, "p1")
        var request = Engagement_V1_UnsavePostRequest()
        request.accountID = MockAuthService.accountID
        request.profileID = profile
        request.postID = "p1"
        #expect(await client.unsavePost(request: request, headers: [:]).error == nil)
        #expect(await client.unsavePost(request: request, headers: [:]).error == nil)

        #expect(try await list(client).isEmpty)
    }

    @Test func anotherAccountIsRefused() async {
        let client = make()
        #expect(await save(client, "p1", account: "acct-someone-else")?.code == .permissionDenied)
    }
}
