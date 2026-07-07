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

    @Test func buildsMonogramAndTime() {
        let model = NotificationDisplayModel(
            item: item(action: .reaction),
            now: Date(timeIntervalSince1970: 1000 + 3600 * 2)
        )
        #expect(model.monogram == "AM")
        #expect(model.timeText == "2h")
    }
}
