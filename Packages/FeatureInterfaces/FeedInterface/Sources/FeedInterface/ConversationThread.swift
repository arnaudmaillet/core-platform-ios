import CoreModels
import MediaCore
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

/// A message's photo, video or voice message (#681, #2103), as the bubble
/// draws it.
public struct ConversationThreadMedia: Equatable, Sendable {
    public enum Kind: Sendable {
        case image
        case video
        case voice
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
    /// A video's or a voice message's length in seconds.
    public let duration: TimeInterval?
    /// A voice message's 100 levels, 0–31 (#2103).
    public let waveform: [UInt8]?
    /// A voice message's asset: the key its audio is cached by.
    public let assetID: String?
    /// The viewer's own take while it is on its way: it plays from here.
    public let localFileURL: URL?

    public init(
        kind: Kind, url: URL?, posterURL: URL? = nil, preview: UIImage? = nil,
        aspectRatio: CGFloat? = nil, duration: TimeInterval? = nil,
        waveform: [UInt8]? = nil, assetID: String? = nil, localFileURL: URL? = nil
    ) {
        self.kind = kind
        self.url = url
        self.posterURL = posterURL
        self.preview = preview
        self.aspectRatio = aspectRatio
        self.duration = duration
        self.waveform = waveform
        self.assetID = assetID
        self.localFileURL = localFileURL
    }
}

extension ConversationThreadMedia {
    /// A voice message in one line: "🎤 Voice message (0:12)" — the inbox
    /// row's, a quote's, the thread's until the bubble draws it (#2103).
    public static func voiceSummary(duration: TimeInterval?) -> String {
        guard let duration else { return "🎤 Voice message" }
        let whole = max(0, Int(duration.rounded()))
        return "🎤 Voice message (\(String(format: "%d:%02d", whole / 60, whole % 60)))"
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
    /// A line about the conversation rather than a message in it (#2214):
    /// "You created the group". Drawn centred and quiet, with no author, no
    /// menu and no reply; `body` is its words.
    public let isSystem: Bool

    public init(
        id: String, senderID: ProfileID, body: String, sentAt: Date, isMine: Bool, quote: Quote?,
        media: ConversationThreadMedia? = nil, delivery: ConversationThreadDelivery = .sent,
        isSystem: Bool = false
    ) {
        self.id = id
        self.senderID = senderID
        self.body = body
        self.sentAt = sentAt
        self.isMine = isMine
        self.quote = quote
        self.media = media
        self.delivery = delivery
        self.isSystem = isSystem
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
    /// The raw @handle, without the "@" (#752). Nil until known.
    public let handle: String?

    public init(id: ProfileID?, name: String, avatarURL: URL?, handle: String? = nil) {
        self.id = id
        self.name = name
        self.avatarURL = avatarURL
        self.handle = handle
    }
}

/// Where a viewer who doesn't post stands in a channel (#2215) or a public
/// group (#2217): what the bar in the composer's place offers, and the way
/// out the footer's ⋯ menu offers.
///
/// The bar shows only what takes the viewer IN; what takes them out — Leave,
/// Unfollow, Cancel Request — is the ⋯ menu's, confirmed (#2236). The mute
/// is the top bar's bell, for everyone.
public enum ConversationThreadReaderStanding: Equatable, Sendable {
    /// Subscribed: no bar (#2236) — the ⋯ menu's Leave Channel.
    case subscribed
    /// Not in a public channel: Join, at once.
    case canJoin
    /// Not in a channel on request: Request to Join.
    case canRequest
    /// Asked, waiting for an admin: Requested — a tap withdraws it, as the
    /// ⋯ menu's Cancel Request does.
    case requested
    /// Banned: nothing to offer but saying so.
    case unavailable
    /// Not in a public group (#2217): Join, to write, or Follow, to read
    /// along — Join only while it has room (`isFull`: "This group is full").
    case canJoinOrFollow(isFull: Bool)
    /// Following a public group (#2217): Join while it has room (#2236:
    /// Join alone); the ⋯ menu's Unfollow.
    case following(isFull: Bool)
    /// The group turned private while the viewer read it from outside
    /// (#2217): nothing left to offer — the thread says so in a line, and
    /// neither the bar nor the composer shows.
    case closed
}

/// A group conversation, as the screen draws it (#2214): its identity for
/// the header, and its members, to sign each row with its sender.
///
/// A DM has none — its header and its rows are the peer
/// (`onPeerChange`). A group has no single peer: without this, every row of
/// a group was signed "Member".
///
/// A CHANNEL is one too (#2215), with `isChannel`: its posts read as a
/// stream under its name and photo — no sender per row, the viewer's own
/// posts included — and a viewer who doesn't post (`readerStanding`) gets
/// a bar instead of the composer.
public struct ConversationThreadGroup: Equatable, Sendable {
    /// Its name, or its members' for a nameless group.
    public let name: String
    public let photoURL: URL?
    /// Under the name in the header: "12 members", "12.4K subscribers".
    public let subtitle: String
    /// The members the screen knows, by id — a row whose sender isn't here
    /// (someone who left) is signed "Member".
    public let members: [ProfileID: ConversationThreadPerson]
    /// A channel (#2215): every row is signed by the channel itself.
    public let isChannel: Bool
    /// Nil while the viewer posts here (a group's members, a channel's owner
    /// and admins); otherwise where they stand, and the bar that shows in
    /// the composer's place (#2215).
    public let readerStanding: ConversationThreadReaderStanding?
    /// The group's faces (#2233): up to four of its other members, owner
    /// first then by join date, and its size for the "+N" — filled by Chat
    /// from the same source as the inbox row, so the pill and the row show
    /// the same faces. Empty: the photo, or the initials.
    public let faces: [GroupAvatarFace]
    /// Everyone in the group, the viewer included; 0 when not known.
    public let memberCount: Int

    public init(
        name: String, photoURL: URL?, subtitle: String, members: [ProfileID: ConversationThreadPerson],
        isChannel: Bool = false, readerStanding: ConversationThreadReaderStanding? = nil,
        faces: [GroupAvatarFace] = [], memberCount: Int = 0
    ) {
        self.name = name
        self.photoURL = photoURL
        self.subtitle = subtitle
        self.members = members
        self.isChannel = isChannel
        self.readerStanding = readerStanding
        self.faces = faces
        self.memberCount = memberCount
    }

    /// What the header pill draws for a group (#2233): its photo, else its
    /// faces, else its initials — the inbox row's picture. Nil for a
    /// channel, which keeps its photo or initials on the person's face.
    public var avatar: GroupAvatarContent? {
        isChannel ? nil : GroupAvatarContent(name: name, photoURL: photoURL, faces: faces, memberCount: memberCount)
    }

    /// Whether the viewer gets the composer (#2215).
    public var canPost: Bool { readerStanding == nil }
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

/// A finished take to send as a voice message (#2102): the recorder's draft
/// (#2101), carried to the driver, which sends it as #2103 does.
public struct ConversationThreadVoiceTake: Equatable, Sendable {
    public let fileURL: URL
    public let duration: TimeInterval
    /// 100 levels, 0–31.
    public let waveform: [UInt8]

    public init(fileURL: URL, duration: TimeInterval, waveform: [UInt8]) {
        self.fileURL = fileURL
        self.duration = duration
        self.waveform = waveform
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
    var onReplyStateChange: ((ConversationThreadReplyDraft?) -> Void)? { get set }
    /// A notice to present: `(title, message)`.
    var onActionNotice: ((String, String) -> Void)? { get set }
    /// Whether the conversation is pinned to the top of the inbox — the
    /// inbox's own pin, so the list behind the screen agrees with it. Nil
    /// while there is no conversation to pin (a draft whose conversation has
    /// not resolved yet). Fired on every change, wherever it was made.
    var onPinnedChange: ((Bool?) -> Void)? { get set }
    /// Whether the viewer muted the conversation's pushes (#719): the thread's
    /// bell. Nil while there is no conversation to mute. Fired on every
    /// change, wherever it was made.
    var onMutedChange: ((Bool?) -> Void)? { get set }
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
    /// Whether the composer records voice messages (#2102).
    var sendsVoice: Bool { get }
    /// Sends a finished take as a voice message (#2102, #2103).
    func send(voice: ConversationThreadVoiceTake)
    func beginReply(to messageID: String)
    func cancelReply()
    func forward(_ messageID: String)
    func delete(_ messageID: String)
    func didTapIdentity()
    /// The toolbar's peer pill (#1524): the peer's profile card.
    func didTapIdentityPill()
    /// Pins the conversation, or unpins it. A no-op while there is nothing to
    /// pin (`onPinnedChange` said nil).
    func togglePinned()
    /// Mutes the conversation, or unmutes it (#719). A no-op while there is
    /// nothing to mute (`onMutedChange` said nil).
    func toggleMuted()
    /// Mutes until `until` — nil: until turned back on — or unmutes (#729):
    /// the bell's long-press durations.
    ///
    /// `completion` answers once the SERVER has (#802): true when the mute was
    /// written, false when it was refused and rolled back. The screen confirms
    /// only then — a "Notifications muted" toast shown on the tap, followed by
    /// a silent rollback, told the viewer something that did not happen.
    func setMuted(_ muted: Bool, until: Date?, completion: @escaping @MainActor (_ confirmed: Bool) -> Void)
    /// Whether the footer offers the camera and the library (#681).
    var sendsMedia: Bool { get }
    /// Lets the viewer pick (or capture) a photo or video, presented over
    /// `presenter`, and sends it.
    func pickMedia(_ source: ConversationThreadMediaSource, from presenter: UIViewController)
    /// Sends a failed message again.
    func retry(_ messageID: String)
    /// The correspondent's profile, made but NOT pushed — what a leftward
    /// swipe on the thread pushes following the finger (#1525). Nil while
    /// the peer is unresolved, or for a conversation with no single peer.
    func peerProfileDestination() -> UIViewController?
    /// Where the thread remembers its last-known shape (#1774) — how many
    /// messages, whether any had media — so its cold skeleton is that shape.
    /// Nil keeps no memory.
    var presenceKey: String? { get }

    /// The conversation is a group (#2214): its header and its members, or
    /// nil for a DM. Fired again as its members resolve.
    var onGroupChange: ((ConversationThreadGroup?) -> Void)? { get set }
    /// The group's header was tapped (#2214): its info screen, pushed from
    /// `presenter`.
    func didTapGroupInfo(from presenter: UIViewController)
    /// A group row's face was tapped (#2214): that member's profile.
    func didTapMember(_ profileID: ProfileID)

    /// The reader bar's Join or Request to Join (#2215): a public channel
    /// subscribes at once, one on request waits for an admin. The answer
    /// arrives as a new `onGroupChange`.
    func join()
    /// The reader bar's Requested, or the ⋯ menu's Cancel Request,
    /// confirmed: the request withdrawn (#2215, #2236).
    func cancelJoinRequest()
    /// The ⋯ menu's Leave Channel, confirmed (#2215, #2236): the viewer
    /// leaves the channel. A channel they can still read stays on screen
    /// with its new standing (Join, Request to Join); one they can't is
    /// closed from `presenter`.
    func leave(from presenter: UIViewController)
    /// The reader bar's Follow (#2217): the viewer subscribes to a public
    /// group — reads along, the group in their inbox, muted. The answer
    /// arrives as a new `onGroupChange`.
    func follow()
    /// The ⋯ menu's Unfollow, confirmed (#2217, #2236): the viewer stops
    /// following; the group leaves their inbox, and they read it as anyone.
    func unfollow()
}

public extension ConversationThreadDriving {
    /// Whether the composer records voice messages (#2102). False: the
    /// waveform keeps "not available".
    var sendsVoice: Bool { false }
    func send(voice: ConversationThreadVoiceTake) {}

    /// Drivers with no mute (#719): no bell.
    var onMutedChange: ((Bool?) -> Void)? {
        get { nil }
        set {}
    }
    func toggleMuted() {}
    /// Nothing to mute: nothing was written.
    func setMuted(_ muted: Bool, until: Date?, completion: @escaping @MainActor (_ confirmed: Bool) -> Void) {
        completion(false)
    }
    /// The same change, for a caller with nothing to say about the answer.
    func setMuted(_ muted: Bool, until: Date?) {
        setMuted(muted, until: until, completion: { _ in })
    }
    /// Drivers with no older history to page through.
    func loadOlder() {}
    /// Drivers that send text only.
    var sendsMedia: Bool { false }
    func pickMedia(_ source: ConversationThreadMediaSource, from presenter: UIViewController) {}
    func retry(_ messageID: String) {}
    /// Drivers with no profile to push.
    func peerProfileDestination() -> UIViewController? { nil }
    /// Drivers with no card: the profile, as the other ways to it.
    func didTapIdentityPill() { didTapIdentity() }
    /// Drivers with no conversation to remember.
    var presenceKey: String? { nil }

    /// Drivers with no groups (#2214): every conversation is a DM.
    var onGroupChange: ((ConversationThreadGroup?) -> Void)? {
        get { nil }
        set {}
    }
    func didTapGroupInfo(from presenter: UIViewController) {}
    /// Drivers with no groups: the one peer's profile.
    func didTapMember(_ profileID: ProfileID) { didTapIdentity() }

    /// Drivers with no channels (#2215): nothing to join or leave.
    func join() {}
    func cancelJoinRequest() {}
    func leave(from presenter: UIViewController) {}

    /// Drivers with no public groups (#2217): nothing to follow.
    func follow() {}
    func unfollow() {}
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
