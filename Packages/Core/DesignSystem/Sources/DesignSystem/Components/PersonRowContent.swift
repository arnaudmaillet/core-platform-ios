import Foundation

/// What a person row *renders* — the four strings and one flag, and nothing
/// else.
///
/// **Deliberately not a feature's display model.** `PersonListCell` used to
/// take Chat's `PersonDisplayModel`, which is why the cell could not leave
/// Chat: that type carries a `ProfileID` and a `ConversationID`, so the cell
/// dragged `CoreModels` behind it, and DesignSystem depends on nothing. Three
/// features now show the same row from three unrelated models — the compose
/// picker's people, the inbox's search hits, and search results — and each
/// projects onto this at the call site.
///
/// Identity is the caller's business. There is no id here on purpose: a row
/// knows how to *look* like a person and nothing about which person, so
/// selection stays keyed by whatever the host's data source already uses.
///
/// A row that is not a person sets `subject` to `.symbol` and keeps everything
/// else — so a list that mixes people with queries or hashtags stays one list
/// with one text margin, rather than two shapes stacked on each other.
public struct PersonRowContent: Equatable, Sendable {
    /// What the leading disc shows.
    ///
    /// Named for the row's SUBJECT, not for the artwork, because that is the
    /// one thing the caller actually knows and the whole point is that every
    /// caller answers it the same way. A row is a person or it is not; the
    /// disc follows.
    public enum Subject: Equatable, Sendable {
        /// A person: initials, with a picture over them when one arrives.
        case person
        /// Not a person — a remembered query, a hashtag. The disc carries
        /// this SF Symbol instead of initials.
        case symbol(String)
    }

    public let subject: Subject
    public let displayName: String
    /// The handle line, rendered exactly as given.
    ///
    /// ⚠️ **Whether it wears an "@" is the caller's decision, not this type's.**
    /// The compose picker passes it bare — every row there is a person and the
    /// second line is always their handle, so the sigil is decoration repeated
    /// down the whole list. A surface where the handle is what was *matched*
    /// may well want it. Neither is normalized here, because a row that
    /// silently added or stripped a sigil would leave its caller unable to say
    /// what it wanted.
    public let handle: String
    /// One or two letters. Never derived here — the callers' models each
    /// already compute it, by rules that differ (display name vs. handle
    /// fallback), and re-deriving would quietly overrule them.
    public let monogram: String
    public let isVerified: Bool
    /// What the row says about this person beside their name — see
    /// `ProfileRowContext`. `.none` renders nothing.
    public let context: ProfileRowContext

    public init(
        displayName: String,
        handle: String,
        monogram: String,
        isVerified: Bool = false,
        subject: Subject = .person,
        context: ProfileRowContext = .none
    ) {
        self.displayName = displayName
        self.handle = handle
        self.monogram = monogram
        self.isVerified = isVerified
        self.subject = subject
        self.context = context
    }
}
