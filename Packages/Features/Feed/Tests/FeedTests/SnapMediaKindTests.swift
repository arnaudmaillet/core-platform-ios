import CoreModels
import Foundation
import MediaCore
import Testing
@testable import Feed

/// The display-model builder must carry a `video/*` attachment through as
/// `MediaKind.video` — that's what routes a snap cell to the player.
struct SnapMediaKindTests {
    private func entry(mimeType: String) -> FeedEntry {
        FeedEntry(
            post: Post(
                id: PostID("p1"),
                authorID: ProfileID("a1"),
                caption: "hi",
                attachments: [MediaAttachment(
                    url: URL(string: "mock://video/0"),
                    thumbnailURL: URL(string: "mock://poster/0"),
                    mimeType: mimeType,
                    pixelWidth: 1080,
                    pixelHeight: 1920
                )],
                publishedAt: Date(timeIntervalSince1970: 0)
            ),
            author: AuthorSummary(id: ProfileID("a1"), handle: "a", displayName: "A", avatarURL: nil),
            likeCount: 0
        )
    }

    @Test func videoAttachmentBecomesVideoKind() {
        let model = FeedDisplayModelBuilder(cellWidth: 390).build([entry(mimeType: "video/mp4")], relativeTo: Date(timeIntervalSince1970: 0)).first
        #expect(model?.mediaKind == .video)
        // The poster URL threads through for the video cell.
        #expect(model?.thumbnailURL == URL(string: "mock://poster/0"))
    }

    @Test func imageAttachmentBecomesImageKind() {
        let model = FeedDisplayModelBuilder(cellWidth: 390).build([entry(mimeType: "image/png")], relativeTo: Date(timeIntervalSince1970: 0)).first
        #expect(model?.mediaKind == .image)
    }
}
