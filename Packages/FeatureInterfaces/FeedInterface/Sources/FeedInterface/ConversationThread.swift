import CoreModels
import UIKit

// MARK: - The conversation, drawn by Feed and driven by Chat

// The conversation screen built from the text post's screen (`-unified-thread`).
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

    public init(id: String, senderID: ProfileID, body: String, sentAt: Date, isMine: Bool, quote: Quote?) {
        self.id = id
        self.senderID = senderID
        self.body = body
        self.sentAt = sentAt
        self.isMine = isMine
        self.quote = quote
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

    func viewDidLoad()
    func refresh()
    func send(_ text: String)
    func beginReply(to messageID: String)
    func cancelReply()
    func forward(_ messageID: String)
    func delete(_ messageID: String)
    func didTapIdentity()
}

/// What sits in the footer where a post shows its music: for a conversation,
/// the emote strip. A view and the one fact it cannot work out — its width.
@MainActor
public protocol ConversationThreadAccessory: AnyObject {
    var view: UIView { get }
    /// Text the accessory wants in the composer (an emote's emoji).
    var onInsertText: ((String) -> Void)? { get set }
    /// A bar item's custom view has no intrinsic width and is not in the
    /// bar's hierarchy before layout, so the host hands it its budget.
    func setPreferredWidth(_ width: CGFloat)
}

@MainActor
public protocol ConversationThreadScreenBuilding {
    /// `driver` is retained by the returned screen for its lifetime.
    func makeConversationThreadViewController(
        driver: any ConversationThreadDriving,
        mode: ConversationThreadMode,
        prefill: String,
        accessory: (any ConversationThreadAccessory)?
    ) -> UIViewController
}
