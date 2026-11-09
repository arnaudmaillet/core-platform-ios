import CoreContracts
import CoreModels
import CoreNetworking
import Foundation
import PostGrid
import Testing
@testable import Feed

/// A voice post (#2206) is a text post whose caption speaks: the voice is
/// mapped from the wire and carried to every projection, and the post stays
/// text in every one of them.
struct PostVoiceProjectionTests {
    private let voice = PostVoice(assetID: "voice-post-bakery", url: URL(string: "https://cdn.example/v.m4a"),
                                  duration: 5.7, waveform: Array(repeating: 12, count: 100))

    private func view(withVoice: Bool, caption: String = "Warm croissants") -> Post_V1_PostView {
        var view = Post_V1_PostView()
        view.postID = "p-voice"
        view.profileID = "prof-1"
        view.kind = .textOnly
        view.caption = caption
        view.publishedAtMs = 1_800_000_000_000
        if withVoice { PostVoiceWire.write(voice, to: &view) }
        return view
    }

    private func entry(_ post: Post) -> FeedEntry {
        FeedEntry(post: post, author: AuthorSummary(id: post.authorID, handle: "ava", displayName: "Ava", avatarURL: nil))
    }

    @Test func makePostMapsAVoiceAndLeavesOthersAlone() {
        let speaking = FeedRepository.makePost(from: view(withVoice: true))
        #expect(speaking.voice == voice)
        #expect(speaking.hasVoice)
        #expect(speaking.attachments.isEmpty, "a voice post read as media")
        let silent = FeedRepository.makePost(from: view(withVoice: false))
        #expect(silent.voice == nil && !silent.hasVoice)
        #expect(silent.caption == "Warm croissants")
    }

    @Test func theFeedPageCarriesItAndStaysText() {
        let post = FeedRepository.makePost(from: view(withVoice: true, caption: ""))
        let model = FeedDisplayModelBuilder().build(entry(post), now: Date())
        #expect(model.voice == voice && model.hasVoice)
        #expect(model.mediaURL == nil, "a voice post got a media page")
        #expect(model.caption == nil)
    }

    @Test func theGridTileCarriesItAndStaysText() {
        let post = FeedRepository.makePost(from: view(withVoice: true))
        let tile = ForYouRepository.galleryPost(from: entry(post))
        #expect(tile.voice == voice && tile.hasVoice)
        #expect(tile.kind == .text)
        // And the page a tile opens is seeded speaking.
        let seeded = GalleryPostProjection.seedModel(from: tile)
        #expect(seeded.voice == voice)
        #expect(seeded.mediaURL == nil)
    }

    @Test func aStoredPostWithoutTheFieldDecodesWithNoVoice() throws {
        let post = FeedRepository.makePost(from: view(withVoice: true))
        let data = try JSONEncoder().encode(post)
        #expect(try JSONDecoder().decode(Post.self, from: data).voice == voice)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["voice"] = nil
        let old = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(Post.self, from: old).voice == nil)
    }
}
