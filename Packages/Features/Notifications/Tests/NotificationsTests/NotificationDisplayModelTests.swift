import CoreModels
import Foundation
import Testing
@testable import Notifications

struct NotificationDisplayModelTests {
    private func item(
        action: NotificationItem.Action,
        sender: String = "Ava Moreau",
        others: Int = 0,
        post: PostID? = PostID("post-1"),
        ageSeconds: TimeInterval = 0
    ) -> NotificationItem {
        NotificationItem(
            id: "n1", action: action, senderID: ProfileID("prof-9"), senderName: sender,
            otherSenderCount: others, postSubjectID: post, isRead: false,
            createdAt: Date(timeIntervalSince1970: 1000)
        )
    }

    private let now = Date(timeIntervalSince1970: 1000)

    @Test func buildsActionSentences() {
        #expect(NotificationDisplayModel(item: item(action: .reaction), now: now).text == "Ava Moreau liked your post")
        #expect(NotificationDisplayModel(item: item(action: .comment), now: now).text == "Ava Moreau commented on your post")
        #expect(NotificationDisplayModel(item: item(action: .reply), now: now).text == "Ava Moreau replied to you")
        #expect(NotificationDisplayModel(item: item(action: .mention), now: now).text == "Ava Moreau mentioned you")
    }

    @Test func aggregatesMultipleSenders() {
        #expect(NotificationDisplayModel(item: item(action: .reaction, others: 1), now: now).text == "Ava Moreau and 1 other liked your post")
        #expect(NotificationDisplayModel(item: item(action: .reaction, others: 3), now: now).text == "Ava Moreau and 3 others liked your post")
    }

    @Test func reactionOnCommentReadsDifferently() {
        // No post subject → it was a reaction on a comment.
        #expect(NotificationDisplayModel(item: item(action: .reaction, post: nil), now: now).text == "Ava Moreau liked your comment")
    }

    @Test func splitsTheSentenceIntoPeopleAndWhatTheyDid() {
        let model = NotificationDisplayModel(item: item(action: .comment, others: 2), now: now)
        #expect(model.actorsText == "Ava Moreau and 2 others")
        #expect(model.phrase == "commented on your post")
        #expect(model.accessibilityText == "Ava Moreau and 2 others commented on your post, just now")
    }

    /// Two faces only when there is a second person to show; the most recent
    /// sender is always the first.
    @Test func facesFollowTheNamedSenders() {
        let avatar = URL(string: "https://example.com/ava.jpg")
        let alone = NotificationItem(
            id: "n1", action: .reaction, senderID: ProfileID("prof-9"), senderName: "Ava Moreau",
            senderAvatarURL: avatar, otherSenderCount: 0, postSubjectID: PostID("p"),
            isRead: false, createdAt: now
        )
        #expect(NotificationDisplayModel(item: alone, now: now).faces
            == [.init(monogram: "AM", avatarURL: avatar)])

        let crowd = NotificationItem(
            id: "n2", action: .reaction, senderID: ProfileID("prof-9"), senderName: "Ava Moreau",
            senderAvatarURL: avatar, otherSenderCount: 3,
            sampleSenders: [NotificationActor(id: ProfileID("prof-2"), name: "Ben Ito", avatarURL: nil)],
            postSubjectID: PostID("p"), isRead: false, createdAt: now
        )
        let faces = NotificationDisplayModel(item: crowd, now: now).faces
        #expect(faces.map(\.monogram) == ["AM", "BI"])
        #expect(faces[1].avatarURL == nil) // initials, never a flat colour
    }

    /// A media post shows its still; a text post shows its words — never both.
    @Test func previewIsAThumbnailOrAnExcerpt() {
        func model(_ preview: NotificationSubjectPreview) -> NotificationDisplayModel {
            NotificationDisplayModel(item: NotificationItem(
                id: "n", action: .reaction, senderID: ProfileID("s"), senderName: "Ava",
                otherSenderCount: 0, postSubjectID: PostID("p"), subjectPreview: preview,
                isRead: false, createdAt: now
            ), now: now)
        }
        let still = URL(string: "https://example.com/still.jpg")
        let media = model(NotificationSubjectPreview(thumbnailURL: still, excerpt: "caption"))
        #expect(media.thumbnailURL == still)
        #expect(media.excerpt == nil)
        let text = model(NotificationSubjectPreview(thumbnailURL: nil, excerpt: "Golden hour."))
        #expect(text.thumbnailURL == nil)
        #expect(text.excerpt == "Golden hour.")
    }

    @Test func buildsMonogramAndTime() {
        let model = NotificationDisplayModel(
            item: item(action: .reaction),
            now: Date(timeIntervalSince1970: 1000 + 3600 * 2)
        )
        #expect(model.monogram == "AM")
        #expect(model.timeText == "2h")
    }
}
