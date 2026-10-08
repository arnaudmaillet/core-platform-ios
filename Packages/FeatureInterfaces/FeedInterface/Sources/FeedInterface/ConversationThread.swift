import CoreModels
import UIKit

// MARK: - The conversation, drawn by Feed and driven by Chat

// The conversation screen, built from the text post's screen.
//
// Feed owns the DRAWING — the post's comment rows, its composer, its header
// frost and footer — because every one of those pieces is Feed's, and a
// conversation is meant to be the same screen. Chat owns the DATA — the
// thread, sending, replies, the inbox bookkeeping — because none of that is
// Feed's business. Features never import each other, so the two meet here, in
// plain values and three small protocols.

/// Whether the screen is the thread itself or the inbox's long-press peek.
public enum ConversationThreadMode: Sendable {
    case full
    /// No composer, no footer, no menu, no refresh — typing and acting are
    /// impossible in a peek.
    case preview
}

/// A message's photo or video (#681), as the bubble draws it.
public struct ConversationThreadMedia: Equatable, Sendable {
    public enum Kind: Sendable {
        case image
        case video
    }

    public let kind: Kind
    /// The picture, or the clip. Nil while a sent message is still uploading.
    public let url: URL?
    /// A video's still.
    public let posterURL: URL?
    /// The picture the viewer picked, drawn while it uploads and after, so
    /// their own message never waits on the network.
    public let preview: UIImage?
    /// Width over height; nil when unknown.
    public let aspectRatio: CGFloat?
    /// A video's length in seconds.
    public let duration: TimeInterval?

    public init(
        kind: Kind, url: URL?, posterURL: URL? = nil, preview: UIImage? = nil,
        aspectRatio: CGFloat? = nil, duration: TimeInterval? = nil
    ) {
        self.kind = kind
        self.url = url
        self.posterURL = posterURL
        self.preview = preview
        self.aspectRatio = aspectRatio
        self.duration = duration
    }
}

/// Where the viewer's own message is: sent, on its way, or failed — a failed
/// one offers a retry (#681).
public enum ConversationThreadDelivery: Equatable, Sendable {
    case sent
    case sending
    case failed
}

/// Where a photo or video to send comes from.
public enum ConversationThreadMediaSource: Equatable, Sendable {
    case camera
    case library
}

/// One message, as the screen needs it.
public struct ConversationThreadMessage: Equatable, Sendable, Identifiable {
    /// The message a reply answers, already resolved to what the row shows.
    public struct Quote: Equatable, Sendable {
        public let messageID: String
        public let author: String
        public let snippet: String

        public init(messageID: String, author: String, snippet: String) {
            self.messageID = messageID
            self.author = author
            self.snippet = snippet
        }
    }

    public let id: String
    public let senderID: ProfileID
    public let body: String
    public let sentAt: Date
    public let isMine: Bool
    public let quote: Quote?
    /// A MEDIA message's photo or video; `body` is then its caption.
    public let media: ConversationThreadMedia?
    public let delivery: ConversationThreadDelivery

    public init(
        id: String, senderID: ProfileID, body: String, sentAt: Date, isMine: Bool, quote: Quote?,
        media: ConversationThreadMedia? = nil, delivery: ConversationThreadDelivery = .sent
    ) {
        self.id = id
        self.senderID = senderID
        self.body = body
        self.sentAt = sentAt
        self.isMine = isMine
        self.quote = quote
        self.media = media
        self.delivery = delivery
    }
}

public enum ConversationThreadPhase: Equatable, Sendable {
    case loading
    /// Oldest first — the thread reads downward to the newest.
    case content([ConversationThreadMessage])
    case failed(String)
}

/// Someone on the thread, as far as the screen can tell.
public struct ConversationThreadPerson: Equatable, Sendable {
    /// Nil until known, and for a group with no single correspondent.
    public let id: ProfileID?
    public let name: String
    public let avatarURL: URL?

    public init(id: ProfileID?, name: String, avatarURL: URL?) {
        self.id = id
        self.name = name
        self.avatarURL = avatarURL
    }
}

/// The message being answered, previewed above the composer.
public struct ConversationThreadReplyDraft: Equatable, Sendable {
    public let messageID: String
    public let author: String
    public let snippet: String

    public init(messageID: String, author: String, snippet: String) {
        self.messageID = messageID
        self.author = author
        self.snippet = snippet
    }
}

/// The thread's data plane, as the screen drives it.
@MainActor
public protocol ConversationThreadDriving: AnyObject {
    var onPhaseChange: ((ConversationThreadPhase) -> Void)? { get set }
    /// The correspondent: the header pill and their rows.
    var onPeerChange: ((ConversationThreadPerson) -> Void)? { get set }
    /// The viewer AS THIS CONVERSATION SENDS: their own rows and the composer's
    /// face. It comes from the driver, not from the comments' active profile,
    /// because the two can differ on an account with several profiles — and a
    /// face that is not the sender is a lie about who is speaking.
    var onViewerChange: ((ConversationThreadPerson) -> Void)? { get set }
    var onSendingChange: ((Bool) -> Void)? { get set }
    var onReplyStateChange: ((ConversationThreadReplyDraft?) -> Void)? { get set }
    /// A notice to present: `(title, message)`.
    var onActionNotice: ((String, String) -> Void)? { get set }
    /// Whether the conversation is pinned to the top of the inbox — the
    /// inbox's own pin, so the list behind the screen agrees with it. Nil
    /// while there is no conversation to pin (a draft whose conversation has
    /// not resolved yet). Fired on every change, wherever it was made.
    var onPinnedChange: ((Bool?) -> Void)? { get set }
    /// An older page of history is on its way (true) or has answered (false):
    /// the screen shows it at the top of the thread (#600).
    var onLoadingOlderChange: ((Bool) -> Void)? { get set }

    func viewDidLoad()
    func refresh()
    /// The reader neared the top: the history before the oldest message
    /// shown, prepended to the next `.content` (#600). A no-op when there is
    /// none, or while a page is on its way.
    func loadOlder()
    func send(_ text: String)
    func beginReply(to messageID: String)
    func cancelReply()
    func forward(_ messageID: String)
    func delete(_ messageID: String)
    func didTapIdentity()
    /// Pins the conversation, or unpins it. A no-op while there is nothing to
    /// pin (`onPinnedChange` said nil).
    func togglePinned()
    /// Whether the footer offers the camera and the library (#681).
    var sendsMedia: Bool { get }
    /// Lets the viewer pick (or capture) a photo or video, presented over
    /// `presenter`, and sends it.
    func pickMedia(_ source: ConversationThreadMediaSource, from presenter: UIViewController)
    /// Sends a failed message again.
    func retry(_ messageID: String)
}

public extension ConversationThreadDriving {
    /// Drivers with no older history to page through.
    func loadOlder() {}
    /// Drivers that send text only.
    var sendsMedia: Bool { false }
    func pickMedia(_ source: ConversationThreadMediaSource, from presenter: UIViewController) {}
    func retry(_ messageID: String) {}
}

@MainActor
public protocol ConversationThreadScreenBuilding {
    /// `driver` is retained by the returned screen for its lifetime.
    func makeConversationThreadViewController(
        driver: any ConversationThreadDriving,
        mode: ConversationThreadMode,
        prefill: String
    ) -> UIViewController
}
