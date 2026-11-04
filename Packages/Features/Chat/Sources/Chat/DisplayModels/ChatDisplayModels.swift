import CoreModels
import DesignSystem
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
    /// The peer's handle, for what a failed follow says (#2049). Nil for a
    /// group, or when the conversation does not carry it.
    public let peerHandle: String?
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
        timeText = conversation.lastActivityAt.map { RelativeAgeFormatter.short(from: $0, to: now) } ?? ""
        monogram = MonogramAvatarView.monogram(name: conversation.title, handle: "")
        peerID = conversation.otherMemberIDs.count == 1 ? conversation.otherMemberIDs.first : nil
        peerHandle = peerID == nil ? nil : conversation.directPeerHandle
        self.isPinned = isPinned
        self.isMuted = isMuted
        self.isUnread = isUnread
        self.unreadCount = unreadCount
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
    /// A MEDIA message's photo, video or voice message (#681, #2103).
    public let media: MediaDisplay?

    /// The message in one line, for a quote: its text, or what it carries.
    public var summary: String {
        guard body.isEmpty, let media else { return body }
        return ChatMedia.summary(kind: media.kind, duration: media.duration)
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
        /// A voice message's 100 levels (#2103).
        public var waveform: [UInt8]? = nil
        /// A voice message's asset — the key its audio is cached by.
        public var assetID: String? = nil
        /// The viewer's own take while it is on its way: it plays from here,
        /// never waiting on the upload (#2103).
        public var localFileURL: URL? = nil
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
                duration: media.duration, waveform: media.waveform, assetID: media.assetID
            )
        }
        delivery = .sent
    }

    /// A photo, video or voice message of the viewer's still on its way, or
    /// failed.
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
        case .voice: nil
        }
        let duration: TimeInterval? = switch upload {
        case .image: nil
        case .video(let video): video.duration
        case .voice(let voice): voice.duration
        }
        var display = MediaDisplay(
            kind: upload.kind, url: nil, posterURL: nil, preview: upload.preview,
            aspectRatio: ratio, duration: duration
        )
        if case .voice(let voice) = upload {
            display.waveform = voice.waveform
            display.localFileURL = voice.fileURL
        }
        media = display
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
