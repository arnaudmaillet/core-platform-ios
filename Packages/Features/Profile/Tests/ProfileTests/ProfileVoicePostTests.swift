import CoreContracts
import CoreModels
import CoreNetworking
import Foundation
import PostGrid
import Testing
@testable import Profile
@testable import ProfileSettings

/// A voice post's profile tile (#2206): a TEXT tile whose caption speaks,
/// kept by the profile's disk tier.
struct ProfileVoicePostTests {
    private let voice = PostVoice(assetID: "voice-long", url: nil, duration: 34, waveform: [1, 2, 3])

    @Test func theTileCarriesTheVoiceAndStaysText() {
        var view = Post_V1_PostView()
        view.postID = "p-voice"
        view.kind = .textOnly
        view.caption = "Listen"
        PostVoiceWire.write(voice, to: &view)
        let tile = HydratedPost(view: view).post
        #expect(tile.voice == voice && tile.hasVoice)
        #expect(tile.kind == .text)
        #expect(tile.pages.isEmpty)

        var silent = view
        silent.unknownFields = .init()
        #expect(HydratedPost(view: silent).post.voice == nil)
    }

    @Test func theDiskTierKeepsTheVoice() throws {
        var tile = GalleryPost(id: PostID("p"), kind: .text, isRepost: false, pages: [], caption: "", publishedAtMS: 1)
        tile.voice = voice
        let record = ProfileDiskRecord.Post(tile)
        let decoded = try JSONDecoder().decode(ProfileDiskRecord.Post.self, from: try JSONEncoder().encode(record))
        #expect(decoded.galleryPost?.voice == voice)
    }
}
