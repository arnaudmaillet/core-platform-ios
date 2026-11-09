import Connect
import CoreContracts
import CoreModels
import CoreNetworkingMocks
import Foundation
import SwiftProtobuf
import Testing
@testable import CoreNetworking

/// A voice post's voice on the wire (#2206) and the mock's voice posts: a
/// text post's caption that speaks — never an attachment, never a sound.
struct PostVoiceTests {
    private let voice = PostVoice(
        assetID: "voice-post-hike", url: URL(string: "https://cdn.example/v.m4a"), duration: 12.6,
        waveform: (0..<100).map { UInt8($0 % 32) }
    )

    // MARK: - The wire

    @Test func aVoiceRidesThePostViewAndSurvivesTheWire() throws {
        var view = Post_V1_PostView()
        view.postID = "p1"
        view.kind = .textOnly
        view.caption = "From the ridge"
        PostVoiceWire.write(voice, to: &view)
        let decoded = try Post_V1_PostView(serializedBytes: try view.serializedData())
        #expect(PostVoiceWire.voice(in: decoded) == voice)
        #expect(decoded.caption == "From the ridge")
        #expect(decoded.attachments.isEmpty, "a voice is never an attachment")
        #expect(!decoded.hasAudioRef, "a voice is never the post's sound")
    }

    @Test func aPostWithoutAVoiceHasNone() {
        var view = Post_V1_PostView()
        view.postID = "p2"
        view.caption = "Just words"
        #expect(PostVoiceWire.voice(in: view) == nil)
    }

    @Test func theWaveformKeepsItsLevels() {
        let levels: [UInt8] = [0, 5, 31, 17, 9]
        #expect(PostVoiceWire.levels(PostVoiceWire.waveformString(levels)) == levels)
    }

    // MARK: - The mock

    private func client() -> (Post_V1_PostServiceClient, GeoDiscovery_V1_GeoDiscoveryServiceClient, MockSocialDataset) {
        let bff = MockBFF()
        let dataset = MockSocialDataset()
        let postStore = MockPostStore()
        MockSocialServices(dataset: dataset, postStore: postStore).register(on: bff)
        MockPostAuthoringService(store: postStore).register(on: bff)
        MockGeoDiscoveryService(dataset: dataset).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        return (Post_V1_PostServiceClient(client: client), GeoDiscovery_V1_GeoDiscoveryServiceClient(client: client), dataset)
    }

    /// About one text post in five speaks, with and without text, from a
    /// few seconds to near a minute; no media post does.
    @Test func aboutOneTextPostInFiveSpeaks() {
        let dataset = MockSocialDataset()
        let texts = dataset.posts.filter { $0.media == nil }
        let speaking = texts.compactMap { dataset.seededVoice(forPostID: $0.postID) }
        let share = Double(speaking.count) / Double(max(1, texts.count))
        #expect(share > 0.1 && share < 0.3, "\(speaking.count) of \(texts.count) text posts speak")
        #expect(speaking.contains { $0.keepsText } && speaking.contains { !$0.keepsText })
        let durations = speaking.map(\.voice.duration)
        #expect((durations.min() ?? 0) < 4 && (durations.max() ?? 0) > 45 && (durations.max() ?? 0) <= 60)
        #expect(speaking.allSatisfy { $0.voice.url != nil && $0.voice.waveform.count == 100 })
        for post in dataset.posts where post.media != nil {
            #expect(dataset.seededVoice(forPostID: post.postID) == nil, "media post \(post.postID) speaks")
        }
    }

    @Test func getPostServesASeededVoice() async throws {
        let (posts, _, dataset) = client()
        let id = try #require(dataset.posts.first { dataset.seededVoice(forPostID: $0.postID) != nil }?.postID)
        var request = Post_V1_GetPostRequest()
        request.postID = id
        let view = try await posts.getPost(request: request, headers: [:]).result.get()
        let served = try #require(PostVoiceWire.voice(in: view))
        #expect(served == dataset.seededVoice(forPostID: id)?.voice)
        #expect(view.attachments.isEmpty && view.kind == .textOnly)
    }

    @Test func createPostKeepsItsVoice() async throws {
        let (posts, _, _) = client()
        var create = Post_V1_CreatePostRequest()
        create.profileID = MockSocialDataset.viewerProfileID
        create.kind = .textOnly
        create.caption = ""
        PostVoiceWire.write(voice, to: &create)
        let created = try await posts.createPost(request: create, headers: [:]).result.get()
        var publish = Post_V1_PublishPostRequest()
        publish.postID = created.postID
        publish.profileID = created.profileID
        _ = try await posts.publishPost(request: publish, headers: [:]).result.get()
        var get = Post_V1_GetPostRequest()
        get.postID = created.postID
        let view = try await posts.getPost(request: get, headers: [:]).result.get()
        #expect(PostVoiceWire.voice(in: view) == voice)
        #expect(view.attachments.isEmpty)
    }
}
