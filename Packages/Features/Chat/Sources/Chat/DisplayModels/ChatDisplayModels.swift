import CoreModels
import Foundation
import UIKit

/// View-ready row for the conversation list.
public struct ConversationDisplayModel: Equatable, Sendable, Identifiable {
    public let id: ConversationID
    public let title: String
    public let preview: String
    public let timeText: String
    public let monogram: String
    /// The other member, when there is exactly one — what an avatar is fetched
    /// for. `nil` for a group, which keeps its initials.
    public let peerID: ProfileID?
    public let isPinned: Bool
    public let isMuted: Bool
    /// Drives the row's whole unread treatment — bold text and a badge — rather
    /// than sorting the conversation into a list of its own.
    public let isUnread: Bool
    /// How many messages are waiting, for the badge on the avatar. Zero
    /// whenever `isUnread` is false; see `Conversation.unreadCount` for what
    /// bounds it.
    public let unreadCount: Int

    public init(
        conversation: Conversation,
        now: Date = Date(),
        isPinned: Bool = false,
        isMuted: Bool = false,
        isUnread: Bool = false,
        unreadCount: Int = 0
    ) {
        id = conversation.id
        title = conversation.title
        preview = conversation.lastMessage
        timeText = conversation.lastActivityAt.map { Self.relativeShort(from: $0, to: now) } ?? ""
        monogram = Self.monogram(conversation.title)
        peerID = conversation.otherMemberIDs.count == 1 ? conversation.otherMemberIDs.first : nil
        self.isPinned = isPinned
        self.isMuted = isMuted
        self.isUnread = isUnread
        self.unreadCount = unreadCount
    }

    static func monogram(_ title: String) -> String {
        let initials = title.split(separator: " ").prefix(2)
            .compactMap { $0.first.map { String($0).uppercased() } }
        return initials.isEmpty ? "?" : initials.joined()
    }

    static func relativeShort(from date: Date, to now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<604_800: return "\(Int(seconds / 86_400))d"
        default: return "\(Int(seconds / 604_800))w"
        }
    }
}

/// View-ready message. `senderID`/`sentAt` stay raw here: day grouping and
/// time formatting belong to the screen that draws it.
public struct MessageDisplayModel: Equatable, Sendable, Identifiable {
    public let id: String
    public let senderID: ProfileID
    public let body: String
    public let sentAt: Date
    public let isMine: Bool
    /// The id of the message this one replies to, if any — resolved into a
    /// quoted preview by the transcript builder.
    public let replyToID: String?
    /// A MEDIA message's photo or video (#681).
    public let media: MediaDisplay?

    /// The message in one line, for a quote: its text, or what it carries.
    public var summary: String {
        guard body.isEmpty, let media else { return body }
        return media.kind.label
    }
    public let delivery: Delivery

    /// The viewer's own message: sent, on its way, or failed (a retry).
    public nonisolated enum Delivery: Equatable, Sendable {
        case sent
        case sending
        case failed
    }

    /// What the bubble draws: the delivered media, and — for the viewer's
    /// own — the picture they picked, so their message never waits on the
    /// network to show.
    public struct MediaDisplay: Equatable, Sendable {
        public let kind: ChatMedia.Kind
        /// Nil while the media is still uploading.
        public let url: URL?
        public let posterURL: URL?
        public let preview: UIImage?
        public let aspectRatio: CGFloat?
        public let duration: TimeInterval?
    }

    public init(message: ChatMessage, preview: UIImage? = nil) {
        id = message.id
        senderID = message.senderID
        body = message.body
        sentAt = message.createdAt
        isMine = message.isMine
        replyToID = message.replyToID
        media = message.media.map { media in
            MediaDisplay(
                kind: media.kind, url: media.url, posterURL: media.posterURL, preview: preview,
                aspectRatio: media.aspectRatio ?? preview.map { $0.size.width / max($0.size.height, 1) },
                duration: media.duration
            )
        }
        delivery = .sent
    }

    /// A photo or video of the viewer's still on its way, or failed.
    init(pending id: String, upload: ChatMediaUpload, sender: ProfileID, sentAt: Date, failed: Bool) {
        self.id = id
        senderID = sender
        body = ""
        self.sentAt = sentAt
        isMine = true
        replyToID = nil
        let ratio: CGFloat? = switch upload {
        case .image(let image): image.size.width / max(image.size.height, 1)
        case .video(let video): video.pixelHeight > 0 ? CGFloat(video.pixelWidth) / CGFloat(video.pixelHeight) : nil
        }
        let duration: TimeInterval? = if case .video(let video) = upload { video.duration } else { nil }
        media = MediaDisplay(
            kind: upload.kind, url: nil, posterURL: nil, preview: upload.preview,
            aspectRatio: ratio, duration: duration
        )
        delivery = failed ? .failed : .sending
    }

    /// A text message of the viewer's on its way, or failed (#719).
    init(pending id: String, text: String, replyTo: String?, sender: ProfileID, sentAt: Date, failed: Bool) {
        self.id = id
        senderID = sender
        body = text
        self.sentAt = sentAt
        isMine = true
        replyToID = replyTo
        media = nil
        delivery = failed ? .failed : .sending
    }
}
