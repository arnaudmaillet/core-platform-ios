import CoreContracts
import CoreModels
import CoreNetworking
import Foundation
import Testing
@testable import Notifications

/// A notification about a channel's showcase (#2216): the subject's preview
/// carries the card, words or not, and the device keeps it.
struct NotificationShowcaseTests {
    private let embed = PostEmbed.channel(ChannelEmbed(conversationID: ConversationID("ch-film"), name: "Film stock club"))

    @Test func thePreviewCarriesTheEmbed() throws {
        var post = Post_V1_PostView()
        post.postID = "p-showcase"
        post.caption = "What came back from the lab"
        PostEmbedWire.write(embed, to: &post)
        let preview = try #require(NotificationsRepository.preview(of: post))
        #expect(preview.embed == embed)
        #expect(preview.excerpt == "What came back from the lab")
        #expect(preview.thumbnailURL == nil)

        // A card alone is still something to show.
        post.caption = ""
        #expect(NotificationsRepository.preview(of: post)?.embed == embed)
    }
}

extension NotificationShowcaseTests {
    @Test func theDeviceKeepsTheEmbed() throws {
        let item = NotificationItem(
            id: "n1", action: .reaction, senderID: ProfileID("prof-9"), senderName: "Ava Moreau",
            otherSenderCount: 0, postSubjectID: PostID("p-showcase"),
            subjectPreview: NotificationSubjectPreview(thumbnailURL: nil, excerpt: "Hi", embed: embed),
            isRead: false, createdAt: Date(timeIntervalSince1970: 1000)
        )
        let record = NotificationsLocalCache.Record(item)
        let decoded = try JSONDecoder().decode(NotificationsLocalCache.Record.self, from: try JSONEncoder().encode(record))
        #expect(decoded.item.subjectPreview?.embed == embed)
    }
}
