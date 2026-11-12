import CoreContracts
import CoreModels
import CoreNetworking
import Foundation
import PostGrid
import Testing
@testable import Profile
@testable import ProfileSettings

/// A channel's showcase on a profile (#2216): a TEXT tile carrying its card,
/// kept by the profile's disk tier.
struct ProfileShowcasePostTests {
    private let embed = PostEmbed.channel(ChannelEmbed(
        conversationID: ConversationID("ch-daily"), name: "Daily light", viewerState: .member
    ))

    @Test func theTileCarriesTheEmbedAndStaysText() {
        var view = Post_V1_PostView()
        view.postID = "p-showcase"
        view.kind = .textOnly
        view.caption = "Tonight's light is up"
        PostEmbedWire.write(embed, to: &view)
        let tile = HydratedPost(view: view).post
        #expect(tile.embed == embed)
        #expect(tile.kind == .text)
        #expect(tile.pages.isEmpty)

        var plain = view
        plain.unknownFields = .init()
        #expect(HydratedPost(view: plain).post.embed == nil)
    }

    @Test func theDiskTierKeepsTheEmbed() throws {
        var tile = GalleryPost(id: PostID("p"), kind: .text, isRepost: false, pages: [], caption: "", publishedAtMS: 1)
        tile.embed = embed
        let record = ProfileDiskRecord.Post(tile)
        let decoded = try JSONDecoder().decode(ProfileDiskRecord.Post.self, from: try JSONEncoder().encode(record))
        #expect(decoded.galleryPost?.embed == embed)
    }
}
