import CoreModels
import MediaCore
import Testing
import UIKit
@testable import PostGrid

/// A stand-in re-dated to its row keeps the author's picture.
///
/// ⚠️ **It used to lose it.** `overrideAgeText` reconfigured the author band
/// with no pipeline, which clears the picture and cannot load it back: the card
/// a text post's dismissal flies home on wore the author's INITIALS for the
/// whole flight and landing hold, then swapped to the photograph when the real
/// row took over — read on device as the avatar reloading on every return.
@MainActor
struct StandInAvatarTests {
    private static let avatar = URL(string: "https://example.test/yuki.jpg")!

    private static func post() -> GalleryPost {
        GalleryPost(
            id: PostID("p"), kind: .text, isRepost: false,
            thumbnailURL: nil, caption: "Third coffee.", publishedAtMS: 0,
            authorID: ProfileID("yuki"), authorName: "Yuki", authorHandle: "yuki.snow",
            authorAvatarURL: avatar, reactionCount: 1, commentCount: 1
        )
    }

    @Test func aRedatedStandInKeepsTheAuthorsPicture() async {
        let pipeline = ImagePipeline(fetcher: PlaceholderImageFetcher())
        await pipeline.store(UIImage(systemName: "person.fill")!, for: Self.avatar)
        let card = PostGridListRowCell(frame: CGRect(x: 0, y: 0, width: 343, height: 200))
        card.configure(with: Self.post(), imagePipeline: pipeline)
        #expect(card.authorBandShowsPicture, "guard: a cached picture draws at configure")

        card.overrideAgeText("7m")

        #expect(card.authorBandShowsPicture, "re-dating the stand-in dropped the picture for the initials")
        #expect(card.renderedAgeText == "7m")
    }
}
