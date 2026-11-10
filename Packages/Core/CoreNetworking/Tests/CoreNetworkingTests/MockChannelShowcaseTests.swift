import Connect
import CoreContracts
import CoreModels
import CoreNetworkingMocks
import Foundation
import SwiftProtobuf
import Testing
@testable import CoreNetworking

/// The mock's channel showcases (#2216): text posts carrying a channel's
/// card, hydrated from the conversation book at every read, served only with
/// the channels seeded.
struct MockChannelShowcaseTests {
    private func backend(seedsChannels: Bool = true) -> MockBackend {
        MockBackend(persistence: UserDefaults(suiteName: "showcases-\(UUID().uuidString)")!, seedsChannels: seedsChannels)
    }

    private func getPost(_ id: String, on backend: MockBackend) async throws -> Post_V1_PostView {
        var request = Post_V1_GetPostRequest()
        request.postID = id
        return try await Post_V1_PostServiceClient(client: backend.makeRPCClient())
            .getPost(request: request, headers: [:]).result.get()
    }

    private func showcase(of channel: String, in dataset: MockSocialDataset) throws -> String {
        try #require(dataset.channelShowcases().first { $0.value.conversationID == channel }?.key)
    }

    // MARK: - The pick

    @Test func everyStateHasAShowcaseAndEachIsAPlainTextPost() {
        let dataset = MockSocialDataset()
        let picked = dataset.channelShowcases()
        let channels = Set(picked.values.map(\.conversationID))
        for channel in ["ch-harbour", "ch-printroom", "ch-film", "ch-botanic", "ch-daily", "ch-ferry-gone", "ch-backroom"] {
            #expect(channels.contains(channel), "no showcase points to \(channel)")
        }
        for postID in picked.keys {
            let record = dataset.post(for: postID)
            #expect(record?.media == nil, "showcase \(postID) is a media post")
            #expect(record?.parentID.isEmpty == true, "showcase \(postID) is a repost")
            #expect(dataset.seededVoice(forPostID: postID) == nil, "showcase \(postID) also speaks")
        }
    }

    // MARK: - Served

    @Test func getPostServesTheCardAndTheAuthorsWords() async throws {
        let backend = backend()
        let id = try showcase(of: "ch-harbour", in: backend.dataset)
        let view = try await getPost(id, on: backend)
        let channel = try #require(PostEmbedWire.embed(in: view)?.channel)
        #expect(channel.conversationID == ConversationID("ch-harbour"))
        #expect(channel.name == "Harbour notes" && channel.visibility == .public)
        #expect(channel.viewerState == ChannelEmbed.ViewerState.none && channel.action == .join)
        #expect(channel.lastMessagePreview?.isEmpty == false, "a public channel's last line")
        #expect(view.caption == backend.dataset.channelShowcase(forPostID: id)?.text)
        #expect(view.kind == .textOnly && view.attachments.isEmpty, "a showcase read as media")
        #expect(!view.hasAudioRef)
    }

    @Test func eachChannelReadsInItsState() async throws {
        let backend = backend()
        func action(_ channel: String) async throws -> ChannelEmbed {
            let id = try showcase(of: channel, in: backend.dataset)
            return try #require(PostEmbedWire.embed(in: try await getPost(id, on: backend))?.channel)
        }
        #expect(try await action("ch-printroom").action == .requestToJoin)
        #expect(try await action("ch-printroom").lastMessagePreview == nil, "an outsider read an on-request channel")
        #expect(try await action("ch-film").action == .requested)
        #expect(try await action("ch-botanic").action == .open)
        #expect(try await action("ch-daily").action == .open)
        let gone = try await action("ch-ferry-gone")
        #expect(gone.availability == .deleted && gone.action == nil)
        let backroom = try await action("ch-backroom")
        #expect(backroom.availability == .private && backroom.action == nil)
        #expect(backroom.name.isEmpty, "a private channel told an outsider its name")
    }

    /// Hydrated at the read: a join made through the chat mock shows on the
    /// next read of the post; so does a request, and its cancel.
    @Test func theNextReadShowsAJoinOrARequest() async throws {
        let backend = backend()
        let chat = ProposedChatClient(client: backend.makeRPCClient())
        let viewer = MockSocialDataset.viewerProfileID

        let harbour = try showcase(of: "ch-harbour", in: backend.dataset)
        let before = try #require(PostEmbedWire.embed(in: try await getPost(harbour, on: backend))?.channel)
        _ = try await chat.call(.subscribe(viewer: viewer, conversationID: "ch-harbour"))
        let after = try #require(PostEmbedWire.embed(in: try await getPost(harbour, on: backend))?.channel)
        #expect(after.viewerState == .subscriber && after.action == .open)
        #expect(after.subscriberCount == before.subscriberCount + 1)

        let printroom = try showcase(of: "ch-printroom", in: backend.dataset)
        _ = try await chat.call(.requestToJoin(viewer: viewer, conversationID: "ch-printroom"))
        #expect(PostEmbedWire.embed(in: try await getPost(printroom, on: backend))?.channel?.action == .requested)
        _ = try await chat.call(.cancelJoinRequest(viewer: viewer, conversationID: "ch-printroom"))
        #expect(PostEmbedWire.embed(in: try await getPost(printroom, on: backend))?.channel?.action == .requestToJoin)
    }

    @Test func withoutTheChannelsNoPostCarriesAnEmbed() async throws {
        let backend = backend(seedsChannels: false)
        let id = try showcase(of: "ch-harbour", in: backend.dataset)
        let view = try await getPost(id, on: backend)
        #expect(PostEmbedWire.embed(in: view) == nil)
        #expect(view.caption == backend.dataset.post(for: id)?.caption, "the post's own words")
    }

    @Test func aShowcasesPinCarriesTheCard() async throws {
        let backend = backend()
        var request = GeoDiscovery_V1_QueryTileRequest()
        var box = GeoDiscovery_V1_Viewport()
        box.swLat = -85
        box.swLng = -180
        box.neLat = 85
        box.neLng = 180
        request.viewport = box
        request.zoomLevel = 2
        let response = try await GeoDiscovery_V1_GeoDiscoveryServiceClient(client: backend.makeRPCClient())
            .queryTile(request: request, headers: [:]).result.get()
        let showcases = response.pins.filter { PostEmbedWire.embed(in: $0) != nil }
        #expect(!showcases.isEmpty, "no showcase reached the map")
        #expect(showcases.allSatisfy { $0.thumbnailURL.isEmpty }, "a showcase's pin has a cover")
    }
}
