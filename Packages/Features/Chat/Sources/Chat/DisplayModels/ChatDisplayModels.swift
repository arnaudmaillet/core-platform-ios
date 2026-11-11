import CoreModels
import DesignSystem
import Foundation
import MediaCore
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
    /// A group's or a channel's own photo (#2214): the row's face instead
    /// of initials.
    public let groupPhotoURL: URL?
    /// A group's picture (#2233): its photo, else its other members' faces
    /// stacked, else its initials — what `GroupAvatarView` draws, the
    /// thread's pill the same. Nil for a DM, and for a channel, which keeps
    /// its photo or initials (one voice, no faces).
    public let groupAvatar: GroupAvatarContent?
    /// Who wrote a group's last message, as the preview is prefixed: their
    /// first name, or "You" (#2214). Nil for a DM, and for a group with no
    /// message yet.
    public let previewSender: String?
    /// "Bob invited you to Night photo walk" while the viewer is invited to
    /// the group (#2214): the row is then an invitation, with Accept and
    /// Decline. Nil otherwise.
    public let invitation: String?
    /// A channel (#2215): the row wears a small megaphone beside its name —
    /// on EVERY channel since #2230, run or followed, now that channels sit
    /// in Chats among the DMs and the groups and the mark is what tells one
    /// apart. Its preview has no sender, and its menu's Delete is Leave.
    public let isChannel: Bool
    /// The viewer runs this channel — owner or admin (#2215): said to
    /// VoiceOver. False for everything else.
    public let runsChannel: Bool
    /// The viewer owns this channel (#2230): Leave sends them to the
    /// transfer first — chat.v1 refuses an owner's Leave.
    public let ownsChannel: Bool

    /// `joinedInvitation`: the viewer accepted this group's invitation ahead
    /// of the next load saying so — the row is a group's like any other.
    public init(
        conversation: Conversation,
        now: Date = Date(),
        isPinned: Bool = false,
        isMuted: Bool = false,
        isUnread: Bool = false,
        unreadCount: Int = 0,
        joinedInvitation: Bool = false
    ) {
        id = conversation.id
        title = conversation.title
        // A channel's row reads its last post's FIRST LINE (#2215): a post
        // runs to paragraphs, and the row is one line.
        let isChannel = conversation.kind == .channel && conversation.identity != nil
        preview = isChannel ? Self.firstLine(of: conversation.lastMessage) : conversation.lastMessage
        timeText = conversation.lastActivityAt.map { RelativeAgeFormatter.short(from: $0, to: now) } ?? ""
        monogram = MonogramAvatarView.monogram(name: conversation.title, handle: "")
        // A group with an identity is never "the peer" (#2214), even with one
        // other member left: its face is its photo or its members'.
        let isGroup = conversation.kind == .group && conversation.identity != nil
        // Nor is a channel's (#2215): its one other member is its owner, not
        // a correspondent.
        peerID = !isGroup && !isChannel && conversation.otherMemberIDs.count == 1 ? conversation.otherMemberIDs.first : nil
        peerHandle = peerID == nil ? nil : conversation.directPeerHandle
        self.isPinned = isPinned
        self.isMuted = isMuted
        self.isUnread = isUnread
        self.unreadCount = unreadCount
        groupPhotoURL = isGroup || isChannel ? conversation.identity?.photoURL : nil
        self.isChannel = isChannel
        runsChannel = isChannel && conversation.identity?.viewerState.runsChannel == true
        ownsChannel = isChannel && conversation.identity?.viewerState == .owner
        groupAvatar = isGroup
            ? GroupAvatarContent(
                name: conversation.title, photoURL: conversation.identity?.photoURL,
                faces: conversation.memberFaces, memberCount: conversation.identity?.memberCount ?? 0
            )
            : nil
        previewSender = isGroup && !conversation.lastMessage.isEmpty
            ? Self.previewSender(isMine: conversation.lastMessageIsMine, name: conversation.lastMessageSenderName)
            : nil
        invitation = isGroup && conversation.identity?.viewerState == .invited && !joinedInvitation
            ? Self.invitationLine(inviter: conversation.invitedByName, group: conversation.title)
            : nil
    }

    /// Whether this row's unread messages count in the Chats badge and the
    /// section headers that add up to it (#2230): everything but a MUTED
    /// CHANNEL. A channel joins muted (WhatsApp's rule) and posts to an
    /// audience; counted, a few followed channels would keep the badge lit
    /// for news nobody asked to be told about. Its row still shows them —
    /// bold, the count. A muted DM or group keeps counting, as before.
    public var countsInBadge: Bool { !(isChannel && isMuted) }

    /// The first non-empty line of a post (#2215), trimmed.
    static func firstLine(of text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }

    /// The preview as the row reads it: "Alice: see you there" in a group,
    /// the message alone in a DM.
    public var previewLine: String {
        guard let previewSender, !preview.isEmpty else { return preview }
        return "\(previewSender): \(preview)"
    }

    /// A group's last sender, as the preview names them (#2214): "You", or
    /// their first name. Nil when the name isn't known — the preview then
    /// stands alone rather than inventing one.
    static func previewSender(isMine: Bool, name: String?) -> String? {
        if isMine { return "You" }
        guard let name else { return nil }
        let first = ChatProfile.firstName(of: name)
        return first.isEmpty ? nil : first
    }

    /// What an invitation row says (#2214).
    static func invitationLine(inviter: String?, group: String) -> String {
        guard let inviter, !inviter.isEmpty else { return "You're invited to \(group)" }
        return "\(ChatProfile.firstName(of: inviter)) invited you to \(group)"
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
