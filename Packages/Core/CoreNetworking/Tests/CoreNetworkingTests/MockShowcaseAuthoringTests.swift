import Connect
import CoreContracts
import CoreModels
import CoreNetworkingMocks
import Foundation
import Testing
@testable import CoreNetworking

/// A showcase published this session (#2216, part 3): the mock's authoring
/// keeps the embed and the place the create request carried, serves the
/// embed back hydrated for the viewer, and stands the post on the map at its
/// place — as the backend will (core-platform-backend#995).
struct MockShowcaseAuthoringTests {
    private func backend(seedsChannels: Bool = true) -> MockBackend {
        MockBackend(
            persistence: UserDefaults(suiteName: "showcase-authoring-\(UUID().uuidString)")!,
            seedsChannels: seedsChannels
        )
    }

    /// The Bercy skatepark, the issue's own example.
    private static let bercy = (lat: 48.8349, lng: 2.3814)

    /// Creates and publishes a text post carrying `embed`, at `place` if any.
    private func publish(
        _ caption: String, embed: PostEmbed?, place: (lat: Double, lng: Double)?, on backend: MockBackend
    ) async throws -> String {
        let posts = Post_V1_PostServiceClient(client: backend.makeRPCClient())
        var create = Post_V1_CreatePostRequest()
        create.profileID = MockSocialDataset.viewerProfileID
        create.kind = .textOnly
        create.caption = caption
        if let embed { PostEmbedWire.write(embed, to: &create) }
        if let place {
            var point = Post_V1_GeoPoint()
            point.lat = place.lat
            point.lng = place.lng
            create.location = point
        }
        let postID = try await posts.createPost(request: create, headers: [:]).result.get().postID
        var publish = Post_V1_PublishPostRequest()
        publish.postID = postID
        publish.profileID = MockSocialDataset.viewerProfileID
        _ = try await posts.publishPost(request: publish, headers: [:]).result.get()
        return postID
    }

    private func getPost(_ id: String, on backend: MockBackend) async throws -> Post_V1_PostView {
        var request = Post_V1_GetPostRequest()
        request.postID = id
        return try await Post_V1_PostServiceClient(client: backend.makeRPCClient())
            .getPost(request: request, headers: [:]).result.get()
    }

    private func pins(around point: (lat: Double, lng: Double), on backend: MockBackend) async throws -> [GeoDiscovery_V1_RadarPin] {
        var request = GeoDiscovery_V1_QueryTileRequest()
        var box = GeoDiscovery_V1_Viewport()
        box.swLat = point.lat - 0.01
        box.swLng = point.lng - 0.01
        box.neLat = point.lat + 0.01
        box.neLng = point.lng + 0.01
        request.viewport = box
        request.zoomLevel = 15
        return try await GeoDiscovery_V1_GeoDiscoveryServiceClient(client: backend.makeRPCClient())
            .queryTile(request: request, headers: [:]).result.get().pins
    }

    /// What the composer sends: the channel as the owner's screen knew it.
    private var harbour: PostEmbed {
        .channel(ChannelEmbed(conversationID: ConversationID("ch-harbour"), name: "Harbour notes", viewerState: .member))
    }

    @Test func theCreatedPostKeepsItsEmbedAndItsPlace() async throws {
        let backend = backend()
        let id = try await publish("Our channel, by the water.", embed: harbour, place: Self.bercy, on: backend)
        let view = try await getPost(id, on: backend)
        #expect(view.kind == .textOnly && view.attachments.isEmpty, "a showcase read as media")
        #expect(!view.hasAudioRef)
        #expect(view.caption == "Our channel, by the water.")
        let channel = try #require(PostEmbedWire.embed(in: view)?.channel)
        #expect(channel.conversationID == ConversationID("ch-harbour"))
        #expect(view.hasLocation)
        #expect(view.location.lat == Self.bercy.lat && view.location.lng == Self.bercy.lng)
    }

    /// Served hydrated, as a seeded showcase is: the card shows the viewer's
    /// standing NOW, not the one the request carried.
    @Test func theEmbedIsReadForTheViewerAtEveryRead() async throws {
        let backend = backend()
        let id = try await publish("Join us", embed: harbour, place: nil, on: backend)
        let first = try #require(PostEmbedWire.embed(in: try await getPost(id, on: backend))?.channel)
        // The viewer is not in Harbour notes: the request's "member" is not
        // what the card says.
        #expect(first.viewerState == ChannelEmbed.ViewerState.none && first.action == .join)
        #expect(first.description.isEmpty == false, "the hydrated channel's description")
        _ = try await ProposedChatClient(client: backend.makeRPCClient())
            .call(.subscribe(viewer: MockSocialDataset.viewerProfileID, conversationID: "ch-harbour"))
        let after = try #require(PostEmbedWire.embed(in: try await getPost(id, on: backend))?.channel)
        #expect(after.action == .open)
    }

    @Test func aPlacedShowcaseStandsOnTheMapWithItsCard() async throws {
        let backend = backend()
        let id = try await publish("At the skatepark", embed: harbour, place: Self.bercy, on: backend)
        let pin = try #require(try await pins(around: Self.bercy, on: backend).first { $0.postID == id })
        #expect(pin.lat == Self.bercy.lat && pin.lng == Self.bercy.lng)
        #expect(pin.thumbnailURL.isEmpty, "a showcase's pin has a cover")
        #expect(PostEmbedWire.embed(in: pin)?.channel?.conversationID == ConversationID("ch-harbour"))
    }

    @Test func withoutAPlaceTheShowcaseIsNotOnTheMap() async throws {
        let backend = backend()
        let id = try await publish("No place", embed: harbour, place: nil, on: backend)
        #expect(!(try await getPost(id, on: backend)).hasLocation)
        #expect(try await pins(around: Self.bercy, on: backend).allSatisfy { $0.postID != id })
    }

    /// Several showcases may point to one channel (#2216 § 4).
    @Test func severalShowcasesPointToOneChannel() async throws {
        let backend = backend()
        let first = try await publish("One", embed: harbour, place: nil, on: backend)
        let second = try await publish("Two", embed: harbour, place: nil, on: backend)
        #expect(first != second)
        for id in [first, second] {
            #expect(PostEmbedWire.embed(in: try await getPost(id, on: backend))?.channel?.conversationID
                == ConversationID("ch-harbour"))
        }
    }

    /// A plain text post (the card removed in the composer) carries neither.
    @Test func aPlainTextPostCarriesNoEmbed() async throws {
        let backend = backend()
        let id = try await publish("Just words", embed: nil, place: nil, on: backend)
        let view = try await getPost(id, on: backend)
        #expect(PostEmbedWire.embed(in: view) == nil)
        #expect(!view.hasLocation)
    }
}
