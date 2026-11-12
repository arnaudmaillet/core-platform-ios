import FeedInterface
import Foundation
import VoiceKit
import VoiceKitUI

/// THE ONE COMPOSER CONTRACT (#2308, the owner, 2026-11-11): a conversation
/// and a post's comments build the same composer (`CommentsInputBar`) from
/// this one value, and declare in it only what genuinely differs between
/// them. Everything else is shared, and no host can make it drift:
///
/// - **the row**, `[avatar][field][attachments…][own bubble]`, the post's
///   column after it where a host has one;
/// - **the own bubble**: the emote button over an empty field, the send
///   over a draft;
/// - **tap to type**, everywhere;
/// - **hold to talk**, wherever `voice` records: the same mic, lock, pause,
///   listen back and send (#2102), with the host's limit;
/// - **the attachments** stand between the field and the own bubble, and
///   hide while the reader writes (`CommentsInputBar.showsAttachments`);
/// - the keyboard ride, the growth with the text and the column staying
///   down, as before.
///
/// BUILT TO GROW: nothing here names a kind of media. A conversation's
/// camera and library are entries in its `attachments`; comments with
/// photos later (#2310) declare the same entries, with no change to the
/// composer. Voice comments (#2309) turn `voice` to `.comment`.
struct ComposerConfiguration {
    /// What the empty field's hold records, and so the host's limit. `.none`:
    /// the field doesn't record, and nothing promises it (no "Hold for
    /// voice" placeholder, no VoiceOver action).
    enum Voice: Equatable {
        case none
        /// A voice message: five minutes, on the clock (#2102).
        case message
        /// A voice comment: a minute (#2309). Declared, not used yet.
        case comment
        /// A voice post's caption: a minute, in seconds (#2209, #2294).
        case post

        /// Whether the field's hold records.
        var records: Bool { self != .none }

        /// The take's limit.
        @MainActor var limit: TimeInterval {
            switch self {
            case .none, .message: VoiceRecorder.maximumDuration
            case .comment: Self.commentLimit
            case .post: TextPostVoice.maximumDuration
            }
        }

        /// How the take's time reads: a message on the clock ("0:30"), a
        /// minute-long voice in seconds ("30″", #2294).
        var timerStyle: VoiceView.TimerStyle {
            switch self {
            case .none, .message: .clock
            case .comment, .post: .seconds
            }
        }

        /// The field's VoiceOver action, where it records.
        var recordActionName: String {
            switch self {
            case .none, .message: "Record voice message"
            case .comment: "Record voice comment"
            case .post: "Record voice post"
            }
        }

        /// A voice comment's minute (#2309, the epic's proposal).
        static let commentLimit: TimeInterval = 60
    }

    /// What the own bubble's smiley opens over an empty field. Today every
    /// host opens EmoteKit's panel in the keyboard's place — the
    /// conversation's sticker strip left with #2305 — so this has one case;
    /// a host's own panel (stickers) would be one more.
    enum Emote: Equatable {
        case emotes
    }

    /// The trailing ACTION COLUMN after the row (`SnapActionColumn`'s
    /// coordinates): a post's stake ★, its slot (repost, sound, Share, the
    /// way back) and its actions — whose faces the host still sets as the
    /// post changes (`railFace`, `showsStake`, …) — or none.
    enum Column: Equatable {
        /// No column: the row runs to the bar's end — a conversation, a
        /// post's comments sheet (#2087).
        case none
        /// A post's column, on the post screens.
        case post
    }

    var voice: Voice
    /// The ORDERED list of what the reader can attach from the row: one
    /// glass bubble per entry, between the field and the own bubble. The
    /// composer only calls an entry's `action`; what is picked travels as a
    /// value the host owns, and the host sends it — the composer never
    /// uploads.
    var attachments: [ComposerAttachmentSource]
    var emote: Emote
    var column: Column

    init(voice: Voice = .none, attachments: [ComposerAttachmentSource] = [], emote: Emote = .emotes, column: Column) {
        self.voice = voice
        self.attachments = attachments
        self.emote = emote
        self.column = column
    }

    /// A conversation: its voice (a message, where its driver sends voice)
    /// and its attachments (`[camera, library]`, #2305), no column.
    static func conversation(voice: Voice, attachments: [ComposerAttachmentSource]) -> Self {
        Self(voice: voice, attachments: attachments, column: .none)
    }

    /// A post's comments on the post screens: no voice (#2309 comes next),
    /// no attachments (#2310 is on hold), the post's column.
    static var comments: Self { Self(voice: .none, attachments: [], column: .post) }

    /// A post's comments in the comments sheet (#2087): the avatar, the
    /// field and the own bubble — no column.
    static var commentsSheet: Self { Self(voice: .none, attachments: [], column: .none) }

    /// Whether `other` lays the composer out the same: the same voice,
    /// emote and column, and the same attachment ENTRIES (ids, glyphs,
    /// labels) — a list that only changed its actions keeps its bubbles.
    func laysOutLike(_ other: Self) -> Bool {
        voice == other.voice && emote == other.emote && column == other.column
            && Self.sameEntries(attachments, other.attachments)
    }

    static func sameEntries(_ lhs: [ComposerAttachmentSource], _ rhs: [ComposerAttachmentSource]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy {
            $0.id == $1.id && $0.symbol == $1.symbol && $0.accessibilityLabel == $1.accessibilityLabel
        }
    }
}

/// What the reader has put in the composer — what "writing" means to the
/// attachments' rule: text, a voice take (on its way or held), and later
/// attachments (#2310). Any of them hides the attachment bubbles, so a
/// picked photo fits the rule without changing it.
struct ComposerDraftContents: OptionSet {
    let rawValue: Int
    static let text = Self(rawValue: 1 << 0)
    static let voiceTake = Self(rawValue: 1 << 1)
    static let attachments = Self(rawValue: 1 << 2)
}
