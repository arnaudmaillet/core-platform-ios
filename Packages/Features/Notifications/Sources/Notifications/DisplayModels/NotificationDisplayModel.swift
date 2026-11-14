import CoreModels
import DesignSystem
import Foundation
import LaunchArguments

/// View-ready projection of a `NotificationItem`: who (the bold part of the
/// sentence, and up to two faces), what they did, when, and what it was about.
public struct NotificationDisplayModel: Equatable, Sendable, Identifiable {
    /// One face in the row's avatar: the picture when there is one, the
    /// initials always (they are what shows until — or instead of — it).
    public struct Face: Equatable, Sendable {
        public let monogram: String
        public let avatarURL: URL?
    }

    public let id: String
    public let action: NotificationItem.Action
    /// The people, as the sentence opens: "Ava Moreau" or "Ava Moreau and 3
    /// others". Drawn bold.
    public let actorsText: String
    /// What they did: "liked your post". Drawn regular.
    public let phrase: String
    /// The whole sentence — the accessibility label's opening, and what the
    /// tests read.
    public let text: String
    public let timeText: String
    /// The primary sender's initials (kept for callers that draw one disc).
    public let monogram: String
    /// One face, or two for a row with more than one sender (the most recent
    /// in front).
    public let faces: [Face]
    /// The subject post's still, drawn at the trailing edge.
    public let thumbnailURL: URL?
    /// A text post's opening, drawn under the sentence — for a voice post
    /// (#2208), "🎙 Voice post · 32″" or its words marked; for a channel's
    /// showcase (#2216), "📣 Harbour notes · " and its words.
    public let excerpt: String?
    public let isRead: Bool

    /// - Parameters:
    ///   - showsVoice: `-voice-posts` (#2208): off, a voice post's row reads
    ///     as the text post it is.
    ///   - showsEmbed: `-channels` (#2216): off, a showcase's row reads as
    ///     the text post it is — PostGrid's `PostEmbeds.areDrawn`, read here
    ///     by name: a row draws no card, so Notifications needs no PostGrid.
    public init(
        item: NotificationItem, now: Date = Date(), showsVoice: Bool = DebugFlags.isOn("-voice-posts"),
        showsEmbed: Bool = DebugFlags.isOn("-channels")
    ) {
        id = item.id
        action = item.action
        actorsText = Self.actors(for: item)
        phrase = Self.phrase(for: item)
        text = "\(actorsText) \(phrase)"
        timeText = RelativeAgeFormatter.short(from: item.createdAt, to: now)
        monogram = MonogramAvatarView.monogram(name: item.senderName, handle: "")
        var faces = [Face(monogram: monogram, avatarURL: item.senderAvatarURL)]
        if item.otherSenderCount > 0, let second = item.sampleSenders.first {
            faces.append(Face(monogram: MonogramAvatarView.monogram(name: second.name, handle: ""), avatarURL: second.avatarURL))
        }
        self.faces = faces
        thumbnailURL = item.subjectPreview?.thumbnailURL
        excerpt = Self.excerpt(of: item.subjectPreview, showsVoice: showsVoice, showsEmbed: showsEmbed)
        isRead = item.isRead
    }

    /// The row as VoiceOver reads it: the sentence, the text it is about, and
    /// how long ago.
    public var accessibilityText: String {
        let when = timeText == "now" ? "just now" : "\(timeText) ago"
        return [text, excerpt, when].compactMap { $0 }.joined(separator: ", ")
    }

    /// The line under the sentence: a text post's opening, a showcase's
    /// channel and words (#2216), or a voice post's text (#2208) — none
    /// under a picture. Pure.
    ///
    /// A showcase's channel comes first: the card is what the post IS
    /// (its caption's place on every surface that draws one), and a row has
    /// room for one mark.
    static func excerpt(of preview: NotificationSubjectPreview?, showsVoice: Bool, showsEmbed: Bool = false) -> String? {
        guard let preview, preview.thumbnailURL == nil else { return nil }
        if showsEmbed, let embed = preview.embed { return embed.previewText(caption: preview.excerpt) }
        guard showsVoice, let voice = preview.voice else { return preview.excerpt }
        return voice.previewText(caption: preview.excerpt)
    }

    private static func actors(for item: NotificationItem) -> String {
        guard item.otherSenderCount > 0 else { return item.senderName }
        return "\(item.senderName) and \(item.otherSenderCount) other\(item.otherSenderCount == 1 ? "" : "s")"
    }

    private static func phrase(for item: NotificationItem) -> String {
        let onPost = item.postSubjectID != nil
        switch item.action {
        case .reaction: return onPost ? "liked your post" : "liked your comment"
        case .comment: return "commented on your post"
        case .reply: return "replied to you"
        case .mention: return "mentioned you"
        // The sender is the other side of the link, either role (#1106).
        case .supervisionStarted: return "is now linked with you for parental supervision"
        case .supervisionEnded: return "ended your parental supervision link"
        case .supervisionCameOfAge: return "is no longer linked with you: supervision ends at 18"
        case .other: return "interacted with you"
        }
    }
}
