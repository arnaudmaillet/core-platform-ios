import CoreContracts
import CoreModels
import CoreNetworking
import Foundation
import PostGrid
import Testing
@testable import Feed

/// A channel's showcase (#2216) is a text post carrying an embed: the embed
/// is mapped from the wire, kept on the device and carried to every
/// projection, and the post stays text in every one of them.
struct PostEmbedProjectionTests {
    private let embed = PostEmbed.channel(ChannelEmbed(
        conversationID: ConversationID("ch-harbour"), name: "Harbour notes", subscriberCount: 10,
        visibility: .public, viewerState: .none
    ))

    private func view(withEmbed: Bool, caption: String = "Come aboard") -> Post_V1_PostView {
        var view = Post_V1_PostView()
        view.postID = "p-showcase"
        view.profileID = "prof-1"
        view.kind = .textOnly
        view.caption = caption
        view.publishedAtMs = 1_800_000_000_000
        if withEmbed { PostEmbedWire.write(embed, to: &view) }
        return view
    }

    private func entry(_ post: Post) -> FeedEntry {
        FeedEntry(post: post, author: AuthorSummary(id: post.authorID, handle: "ava", displayName: "Ava", avatarURL: nil))
    }

    @Test func makePostMapsAnEmbedAndLeavesOthersAlone() {
        let showcase = FeedRepository.makePost(from: view(withEmbed: true))
        #expect(showcase.embed == embed)
        #expect(showcase.attachments.isEmpty, "a showcase read as media")
        #expect(showcase.caption == "Come aboard")
        let plain = FeedRepository.makePost(from: view(withEmbed: false))
        #expect(plain.embed == nil)
    }

    @Test func theFeedPageCarriesItAndStaysText() {
        let post = FeedRepository.makePost(from: view(withEmbed: true))
        let model = FeedDisplayModelBuilder().build(entry(post), now: Date())
        #expect(model.embed == embed)
        #expect(model.mediaURL == nil, "a showcase got a media page")
        #expect(model.caption == "Come aboard")
    }

    @Test func theGridTileCarriesItAndStaysText() {
        let post = FeedRepository.makePost(from: view(withEmbed: true))
        let tile = ForYouRepository.galleryPost(from: entry(post))
        #expect(tile.embed == embed)
        #expect(tile.kind == .text)
        #expect(tile.pages.isEmpty)
        // And the page a tile opens is seeded with its card.
        let seeded = GalleryPostProjection.seedModel(from: tile)
        #expect(seeded.embed == embed)
        #expect(seeded.mediaURL == nil)
    }

    /// The trap voice posts hit: the device cache must WRITE the embed back,
    /// or a cold launch reads the showcase as a plain text post.
    @Test func theDeviceCacheKeepsTheEmbed() {
        let post = FeedRepository.makePost(from: view(withEmbed: true))
        let stored = FeedLocalCache.postView(from: post)
        #expect(PostEmbedWire.embed(in: stored) == embed)
        #expect(FeedRepository.makePost(from: stored).embed == embed)
        #expect(stored.attachments.isEmpty)
    }
}
