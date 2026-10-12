import CacheKit
import Foundation

/// Whose copies of server data the store holds (decision 4, epic #890: a
/// logout, an account switch or a profile switch wipes them).
///
/// The app maps its `StorageScope` owner onto this: nobody yet (`unscoped`,
/// before the first render) is `nil`, and a store asked as nobody answers
/// nothing and writes nothing.
public enum LocalStoreViewer: Hashable, Sendable {
    case guest
    /// `profile` is nil until the account's active profile is resolved. At
    /// cold start that takes a network call, so an offline launch never gets
    /// past it: a member whose profile is not known yet may read what the same
    /// account stored (`isSamePerson`). A profile SWITCH is a change of viewer
    /// and wipes the store before the next profile reads anything.
    case member(account: String, profile: String?)

    /// Whether `self` and `other` can be the same person: the same guest, or
    /// the same account with the same profile, or a profile not known yet on
    /// either side.
    public func isSamePerson(as other: LocalStoreViewer) -> Bool {
        switch (self, other) {
        case (.guest, .guest):
            return true
        case let (.member(account, profile), .member(otherAccount, otherProfile)):
            guard account == otherAccount else { return false }
            guard let profile, let otherProfile else { return true }
            return profile == otherProfile
        default:
            return false
        }
    }

    /// The more specific of two viewers that are the same person: a resolved
    /// profile wins over an unknown one.
    func merged(with other: LocalStoreViewer) -> LocalStoreViewer {
        switch (self, other) {
        case (.member(let account, nil), .member(_, let profile?)):
            return .member(account: account, profile: profile)
        default:
            return self
        }
    }

    /// How the owner is written in the file's `meta` table.
    var encoded: String {
        switch self {
        case .guest: "guest"
        case .member(let account, nil): "member\u{1F}\(account)"
        case .member(let account, let profile?): "member\u{1F}\(account)\u{1F}\(profile)"
        }
    }

    init?(encoded: String) {
        let parts = encoded.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
        switch (parts.first, parts.count) {
        case ("guest", 1): self = .guest
        case ("member", 2): self = .member(account: parts[1], profile: nil)
        case ("member", 3): self = .member(account: parts[1], profile: parts[2])
        default: return nil
        }
    }
}

/// One entity's identity: its kind (`post`, `profile`, …) and its server id.
/// The same post in two lists is ONE row: lists hold keys, not copies, so a
/// fresher copy written by one list is what every list reads.
public struct LocalEntityKey: Hashable, Sendable {
    public let type: String
    public let id: String

    public init(type: String, id: String) {
        self.type = type
        self.id = id
    }
}

/// An entity to store.
public struct LocalEntityWrite: Sendable {
    public var key: LocalEntityKey
    /// The entity's bytes: its protobuf wire bytes for server entities, so the
    /// table does not follow every contract change.
    public var payload: Data
    /// The payload's encoding, chosen by the type's owner. A reader that does
    /// not know a format treats the row as a miss.
    public var format: Int
    /// How long the copy may be shown at all. Freshness (when to revalidate)
    /// is the reader's call, from `LocalEntity.fetchedAt`.
    public var lifetime: TimeInterval
    /// Only for an entity written on its own (`LocalStore.write(_:as:)`): an
    /// entity a list page carries is kept by the page, and goes with it.
    public var tier: CacheTier

    public init(key: LocalEntityKey, payload: Data, format: Int = 1, lifetime: TimeInterval, tier: CacheTier = .recent) {
        self.key = key
        self.payload = payload
        self.format = format
        self.lifetime = lifetime
        self.tier = tier
    }
}

/// An entity as stored.
public struct LocalEntity: Sendable, Equatable {
    public let key: LocalEntityKey
    public let payload: Data
    public let format: Int
    public let fetchedAt: Date
    public let expiresAt: Date

    public init(key: LocalEntityKey, payload: Data, format: Int, fetchedAt: Date, expiresAt: Date) {
        self.key = key
        self.payload = payload
        self.format = format
        self.fetchedAt = fetchedAt
        self.expiresAt = expiresAt
    }
}

/// One network page of a list (a timeline, a profile grid, a comment thread),
/// written in one transaction with the entities it carries.
public struct LocalListPage: Sendable {
    /// The list's entries in order. An entry already in the list (a post a
    /// ranking served again on a later page) is kept where it first appeared.
    public var items: [LocalEntityKey]
    /// The entities the page carries: its entries, and what they need beside
    /// them (authors, counters), which the page holds as attachments.
    public var entities: [LocalEntityWrite]
    /// The cursor that fetches the page after this one; nil when the list
    /// ends here.
    public var nextCursor: String?
    /// The first page of a tab is `retained`; later pages the viewer scrolled
    /// to are `recent`; pages fetched ahead of the viewer (#970) are
    /// `speculative`, and become `recent` once read.
    public var tier: CacheTier

    public init(items: [LocalEntityKey], entities: [LocalEntityWrite], nextCursor: String?, tier: CacheTier) {
        self.items = items
        self.entities = entities
        self.nextCursor = nextCursor
        self.tier = tier
    }
}

/// A stored list, read back: its entities in order and the cursor to go on
/// from where it stops.
public struct LocalList: Sendable, Equatable {
    public let key: String
    /// In list order. Entries whose entity is missing or expired are left out.
    public let entries: [LocalEntity]
    /// The entities the pages carried besides their entries (authors,
    /// counters), by key.
    public let attachments: [LocalEntityKey: LocalEntity]
    /// The cursor after the last stored page: where the next network page
    /// starts. Persisted per list, so paging goes on after a cold start.
    public let nextCursor: String?
    public let pageCount: Int
    /// When the first page was fetched: the list's age.
    public let fetchedAt: Date
}

/// One item of a transcript (a message), to store or as stored.
public struct LocalTranscriptItem: Sendable, Equatable {
    /// Its server id: an item stored twice (a live copy, then the page that
    /// carries it) is one row, the later copy's.
    public var id: String
    /// Its time in milliseconds: the transcript's order, `id` breaking ties.
    public var sortKey: Int64
    public var payload: Data
    /// The payload's encoding, chosen by the type's owner. A reader that does
    /// not know a format treats the item as unreadable.
    public var format: Int

    public init(id: String, sortKey: Int64, payload: Data, format: Int = 1) {
        self.id = id
        self.sortKey = sortKey
        self.payload = payload
        self.format = format
    }
}

/// One network page of a transcript: items in any order, and the cursor that
/// fetches the items older than its oldest.
public struct LocalTranscriptPage: Sendable {
    public var items: [LocalTranscriptItem]
    /// Nil when nothing is older: the page reaches the transcript's start.
    public var olderCursor: String?

    public init(items: [LocalTranscriptItem], olderCursor: String?) {
        self.items = items
        self.olderCursor = olderCursor
    }
}

/// A stored transcript, read back: its newest items, oldest first, and where
/// paging goes on past the oldest.
public struct LocalTranscript: Sendable, Equatable {
    public let key: String
    public let items: [LocalTranscriptItem]
    /// The cursor for the items older than the oldest stored one; nil when
    /// the stored items reach the transcript's start.
    public let olderCursor: String?
    /// When the newest page was last written.
    public let fetchedAt: Date
}

/// The freshness rules of §4.2 in the device cache report (#890). Writers
/// pass these lifetimes; readers revalidate from `fetchedAt`.
public enum LocalStorePolicy {
    /// The last conversations kept on the device, and the newest messages of
    /// each (decided 2026-10-11, epic #890: 50 × 200). Older messages page
    /// from the network.
    public static let transcriptCount = 50
    public static let transcriptLength = 200
    /// A transcript is shown for 30 days after its newest page was written:
    /// the viewer's own conversations, readable offline long after a feed is.
    public static let transcriptLifetime: TimeInterval = 30 * 24 * 60 * 60
    /// A post may be shown for 7 days; revalidated on display after an hour.
    public static let postLifetime: TimeInterval = 7 * 24 * 60 * 60
    public static let postRevalidation: TimeInterval = 60 * 60
    /// Counters ride with their post; revalidated after a minute.
    public static let counterLifetime: TimeInterval = 7 * 24 * 60 * 60
    public static let counterRevalidation: TimeInterval = 60
    /// Profiles: stale-while-revalidate after 10 minutes.
    public static let profileLifetime: TimeInterval = 7 * 24 * 60 * 60
    public static let profileRevalidation: TimeInterval = 10 * 60
    /// A list page set (first page and the pages after it) expires a day
    /// after its first page was fetched.
    public static let listLifetime: TimeInterval = 24 * 60 * 60
}
