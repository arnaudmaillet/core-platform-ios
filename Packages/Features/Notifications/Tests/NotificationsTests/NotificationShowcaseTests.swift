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

/// A showcase's row (#2216, part 2): no card fits a notification, so it says
/// the channel — "📣 Film stock club" and the author's words — and, with the
/// switch off, reads as the text post it is.
extension NotificationShowcaseTests {
    private func showcaseItem(excerpt: String?, thumbnail: URL? = nil) -> NotificationItem {
        NotificationItem(
            id: "n1", action: .reaction, senderID: ProfileID("prof-9"), senderName: "Ava Moreau",
            otherSenderCount: 0, postSubjectID: PostID("p-showcase"),
            subjectPreview: NotificationSubjectPreview(thumbnailURL: thumbnail, excerpt: excerpt, embed: embed),
            isRead: false, createdAt: Date(timeIntervalSince1970: 1000)
        )
    }

    @Test func theRowSaysTheChannelAndTheWords() {
        let model = NotificationDisplayModel(
            item: showcaseItem(excerpt: "What came back"), now: Date(timeIntervalSince1970: 1000),
            showsVoice: false, showsEmbed: true
        )
        #expect(model.excerpt == "📣 Film stock club · What came back")
        #expect(model.accessibilityText.contains("📣 Film stock club"))
    }

    @Test func aCardAloneSaysTheChannel() {
        let model = NotificationDisplayModel(
            item: showcaseItem(excerpt: nil), now: Date(timeIntervalSince1970: 1000), showsVoice: false, showsEmbed: true
        )
        #expect(model.excerpt == "📣 Film stock club")
    }

    @Test func theSwitchOffReadsAsTheTextPost() {
        let now = Date(timeIntervalSince1970: 1000)
        let words = NotificationDisplayModel(item: showcaseItem(excerpt: "What came back"), now: now, showsVoice: false, showsEmbed: false)
        #expect(words.excerpt == "What came back")
        let alone = NotificationDisplayModel(item: showcaseItem(excerpt: nil), now: now, showsVoice: false, showsEmbed: false)
        #expect(alone.excerpt == nil)
    }
}
