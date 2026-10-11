import Connect
import CoreContracts
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing

/// The client key chat.v1 `SendMessage` and post.v1 `CreatePost` carry
/// (#795), and the mocks holding it to the contracts' shape.
struct IdempotencyKeyTests {
    @Test func aMintedKeyIsOneTheContractsAccept() {
        let key = IdempotencyKey.mint()
        #expect(IdempotencyKey.isValid(key))
        #expect(IdempotencyKey.wire(key) == key, "a valid key went out changed")
        #expect(IdempotencyKey.mint() != key)
    }

    @Test func theContractsShapeIsEightToSixtyFourLettersDigitsDashesAndUnderscores() {
        #expect(IdempotencyKey.isValid("abcDEF09"))
        #expect(IdempotencyKey.isValid("a_b-c_d-" + String(repeating: "x", count: 56)))
        #expect(!IdempotencyKey.isValid("short"))
        #expect(!IdempotencyKey.isValid(String(repeating: "x", count: 65)))
        #expect(!IdempotencyKey.isValid("has.a.dot"))
        #expect(!IdempotencyKey.isValid("clé-avec-accent"))
    }

    /// Any other shape goes out as a stable, valid digest — one per key.
    @Test func aKeyOfAnotherShapeGoesOutAsItsDigest() {
        let wire = IdempotencyKey.wire("k.poster")
        #expect(IdempotencyKey.isValid(wire))
        #expect(wire == IdempotencyKey.wire("k.poster"))
        #expect(wire != IdempotencyKey.wire("k.other"))
        #expect(IdempotencyKey.wire("") == "", "empty is no deduplication, not a key")
    }

    /// Only ABORTED that says the keyed write is in flight — by its code or
    /// by the services' own text — is the one to wait out.
    @Test func onlyTheInFlightAbortedIsInFlight() {
        let fleet = ConnectError(code: .aborted, message: "a send with this idempotency key is in flight in conversation c")
        #expect(IdempotencyKey.isInFlight(fleet, code: "CHT-1013"))
        #expect(IdempotencyKey.isInFlight(ConnectError(code: .aborted, message: "PST-1010: busy"), code: "PST-1010"))
        #expect(!IdempotencyKey.isInFlight(ConnectError(code: .aborted, message: "transaction aborted"), code: "CHT-1013"))
        #expect(!IdempotencyKey.isInFlight(ConnectError(code: .unavailable, message: "CHT-1013"), code: "CHT-1013"))
        #expect(!IdempotencyKey.isInFlight(nil, code: "CHT-1013"))
    }

    /// The mock refuses a key the fleet would (CHT-2010), and answers a
    /// repeated one with the message it first stored.
    @Test func theMockChatServiceHoldsTheKeyToTheContract() async throws {
        let bff = MockBFF()
        MockChatService(dataset: MockSocialDataset()).register(on: bff)
        let client = Chat_V1_ChatServiceClient(
            client: ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        )
        var request = Chat_V1_SendMessageRequest()
        request.conversationID = "conv-1"
        request.senderID = MockSocialDataset.viewerProfileID
        request.body = "Once"
        request.idempotencyKey = "bad"

        let refused = await client.sendMessage(request: request, headers: [:])
        #expect(refused.error?.code == .invalidArgument)

        request.idempotencyKey = IdempotencyKey.mint()
        let first = try #require(await client.sendMessage(request: request, headers: [:]).message)
        let again = try #require(await client.sendMessage(request: request, headers: [:]).message)
        #expect(again.messageID == first.messageID)

        request.idempotencyKey = ""
        let keyless = try #require(await client.sendMessage(request: request, headers: [:]).message)
        #expect(keyless.messageID != first.messageID, "no key, no deduplication")
    }

    /// The mock refuses a key the fleet would (PST-9006), and answers a
    /// repeated one with the post it first created.
    @Test func theMockPostServiceHoldsTheKeyToTheContract() async throws {
        let bff = MockBFF()
        let posts = MockPostStore()
        MockPostAuthoringService(store: posts).register(on: bff)
        let client = Post_V1_PostServiceClient(
            client: ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        )
        var request = Post_V1_CreatePostRequest()
        request.profileID = MockSocialDataset.viewerProfileID
        request.caption = "Once"
        request.idempotencyKey = "bad"

        let refused = await client.createPost(request: request, headers: [:])
        #expect(refused.error?.code == .invalidArgument)

        request.idempotencyKey = IdempotencyKey.mint()
        let first = try #require(await client.createPost(request: request, headers: [:]).message)
        let again = try #require(await client.createPost(request: request, headers: [:]).message)
        #expect(again.postID == first.postID)
        #expect(posts.createdCount == 1)

        request.profileID = "another-profile"
        let other = try #require(await client.createPost(request: request, headers: [:]).message)
        #expect(other.postID != first.postID, "a key is scoped to its profile")
        #expect(posts.createdCount == 2)

        // A post is published once: post.v1 refuses a second PublishPost
        // (PST-1002, ALREADY_EXISTS).
        var publish = Post_V1_PublishPostRequest()
        publish.postID = first.postID
        publish.profileID = MockSocialDataset.viewerProfileID
        #expect(await client.publishPost(request: publish, headers: [:]).message != nil)
        let repeated = await client.publishPost(request: publish, headers: [:])
        #expect(repeated.error?.code == .alreadyExists)
        #expect(posts.publishedCount == 1)
    }
}
