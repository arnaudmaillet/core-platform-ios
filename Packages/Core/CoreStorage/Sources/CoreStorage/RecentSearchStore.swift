import Foundation

/// One entry in the viewer's search history.
///
/// `kind` exists before anything writes a second case on purpose. v1 records
/// only submitted queries, but the surface this feeds — a recent-searches list —
/// is the natural home for "profiles you looked at" too, and adding that later
/// to a `[String]` on disk would be a migration. A `Codable` struct with a kind
/// makes it an additive change instead.
public struct RecentSearch: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// Text the viewer submitted.
        case query
        /// A profile the viewer opened from search — a suggested person, a
        /// completion, or a row in this history.
        case profile
    }

    /// Stable identity, and the de-duplication key. For a query this is the
    /// text folded to lowercase; for a profile, `"profile:<id>"`.
    public let id: String
    public let kind: Kind
    /// What the row shows, in the casing the viewer last used.
    public let text: String
    /// The second line, when there is one — a profile's handle, bare. Queries
    /// have none, and a row with one line is the common case.
    public let subtitle: String?
    /// The person this entry points at, for `.profile` entries.
    ///
    /// Stored beside `id` rather than parsed back out of it. `id` is a
    /// composite ("profile:<id>") because it is the DE-DUPLICATION key and has
    /// to not collide with a query of the same text; picking the raw id out of
    /// that string at every call site would make the key's format load-bearing
    /// everywhere instead of here.
    public let profileID: String?
    /// The person's picture, for `.profile` entries.
    ///
    /// ⚠️ **Stored, and allowed to go stale.** Media URLs from the backend are
    /// presigned and expire, so a row remembered weeks ago may hold a link
    /// that no longer resolves. That is survivable precisely because the disc
    /// falls back to initials when the image does not load — the row is still
    /// correct, just less pretty. The alternative, re-fetching every
    /// remembered person on every appearance of the search screen, is a
    /// `GetProfileById` per row for decoration.
    public let avatarURL: String?
    /// When this was last searched.
    ///
    /// ⚠️ **Informational, not the sort key.** Order comes from position in the
    /// stored array — newest at index 0 — because that is what survives a clock
    /// that moved, a device that changed timezone, or two entries recorded in
    /// the same millisecond. Nothing reads this yet; it is here so a future
    /// "clear searches older than…" has something to ask.
    public let searchedAtMS: Int64

    public init(
        id: String,
        kind: Kind,
        text: String,
        subtitle: String? = nil,
        profileID: String? = nil,
        avatarURL: String? = nil,
        searchedAtMS: Int64
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.subtitle = subtitle
        self.profileID = profileID
        self.avatarURL = avatarURL
        self.searchedAtMS = searchedAtMS
    }

    /// A submitted query. Returns nil for anything that is only whitespace —
    /// a blank row in a history is worse than a short history.
    public static func query(_ text: String, searchedAtMS: Int64) -> RecentSearch? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return RecentSearch(
            id: trimmed.lowercased(),
            kind: .query,
            text: trimmed,
            searchedAtMS: searchedAtMS
        )
    }

    /// A person the viewer opened from search.
    ///
    /// Keyed on the id, not the name: two people can share a display name, and
    /// one person who renames themselves is still the same entry rather than a
    /// second one. The `"profile:"` prefix keeps that key clear of a query
    /// that happens to be the same string.
    ///
    /// Falls back to the handle when there is no display name, and returns nil
    /// only when there is nothing to route to or nothing to render.
    public static func profile(
        id: String,
        displayName: String,
        handle: String,
        avatarURL: String? = nil,
        searchedAtMS: Int64
    ) -> RecentSearch? {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let bareHandle = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = name.isEmpty ? bareHandle : name
        guard !id.isEmpty, !shown.isEmpty else { return nil }
        return RecentSearch(
            id: "profile:" + id,
            kind: .profile,
            text: shown,
            // Bare, like every other handle the app renders under a name.
            subtitle: bareHandle.isEmpty || bareHandle == shown ? nil : bareHandle,
            profileID: id,
            avatarURL: avatarURL,
            searchedAtMS: searchedAtMS
        )
    }
}

/// The queries the viewer has searched, newest first.
///
/// **Client-side, and that is the whole truth rather than a stand-in for it.**
/// No wire contract carries search history — `search.v1` has `Search`,
/// `Suggest` and `MultiSearch`, all of them stateless reads, and no service
/// anywhere accepts or returns a "recent searches" list. That is the same
/// footing `PostBookmarkStore` and `MapFavoritesStore` stand on, and this
/// follows their shape deliberately.
///
/// ⚠️ It also means what this is NOT. A history that lives on the device does
/// not follow the viewer to another one and does not survive deleting the app.
/// When a real seam arrives this becomes a local cache in front of it, and the
/// reconciliation is the interesting part.
public final class RecentSearchStore: @unchecked Sendable {
    /// How many entries are KEPT. Beyond this the oldest fall off the end.
    ///
    /// A history is not an archive: past a certain depth the viewer is
    /// scrolling someone else's past self, and every entry retained is one
    /// more thing to have to delete. Twenty is roughly a fortnight of ordinary
    /// use and four screens of rows.
    public static let storageLimit = 20

    /// How many are SHOWN before the list offers to expand — see `window`.
    ///
    /// Ten, against a `storageLimit` of twenty: the collapsed list is most of
    /// the history rather than a teaser of it, so "See more" is an occasional
    /// row instead of a permanent one. A viewer whose last ten searches are on
    /// screen rarely needs the rest, and the ones who do get them in one tap.
    public static let collapsedLimit = 10

    private static let key = "search.recentQueries"

    private let defaults: UserDefaults
    private let lock = NSLock()
    private let now: @Sendable () -> Int64

    /// Fires after every change, on whatever thread made it — the search
    /// screen re-reads from this rather than polling.
    public var onChange: (() -> Void)?

    /// `now` is injectable so tests can pin timestamps. Ordering never depends
    /// on it (see `RecentSearch.searchedAtMS`), so a frozen clock in a test
    /// changes nothing about what the store does.
    public init(
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.defaults = defaults
        self.now = now
        #if DEBUG
        // `-reset-recent-searches`: deterministic QA, so a scripted launch
        // always starts from an empty history. The bookmark store carries the
        // same hook for the same reason.
        if ProcessInfo.processInfo.arguments.contains("-reset-recent-searches") {
            defaults.removeObject(forKey: Self.key)
        }
        // `-seed-recent-searches a,b,c`: a history without having to submit
        // three searches by hand first. Listed newest-first, which is the
        // order they render in. Seeding more than `collapsedLimit` is how the
        // "See more" row gets exercised.
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-seed-recent-searches"),
           index + 1 < ProcessInfo.processInfo.arguments.count {
            let stamp = self.now()
            let seeded = ProcessInfo.processInfo.arguments[index + 1]
                .split(separator: ",")
                .compactMap { RecentSearch.query(String($0), searchedAtMS: stamp) }
            write(Array(seeded.prefix(Self.storageLimit)))
        }
        #endif
    }

    // MARK: - Reading

    /// Newest first.
    public var recents: [RecentSearch] {
        lock.withLock { read() }
    }

    // MARK: - Writing

    /// Records a search, moving it to the front if it is already there.
    ///
    /// **Moved, not duplicated, and the newer casing wins.** Searching "Ada"
    /// after "ada" is the same search said twice — two rows would be a history
    /// arguing with itself — so the entry is replaced in place at the front and
    /// the text the viewer last typed is what the row then shows.
    public func record(_ entry: RecentSearch) {
        lock.withLock {
            var entries = read()
            let existing = entries.first { $0.id == entry.id }
            entries.removeAll { $0.id == entry.id }
            entries.insert(merged(entry, over: existing), at: 0)
            write(Array(entries.prefix(Self.storageLimit)))
        }
        onChange?()
    }

    /// Keeps what the previous copy of an entry knew and the new one does not.
    ///
    /// ⚠️ **A re-record must not be able to forget.** The same person is
    /// recorded from several places and they know different amounts: opening
    /// them from Suggestions carries a picture, opening them from a typeahead
    /// completion carries only a handle and an id. Without this, tapping the
    /// remembered row a second time — or reaching them by the thinner route —
    /// overwrote the avatar with nil and the row silently fell back to
    /// initials, which is exactly the bug this rule exists to prevent.
    private func merged(_ entry: RecentSearch, over existing: RecentSearch?) -> RecentSearch {
        guard let existing, entry.kind == .profile, existing.kind == .profile else { return entry }
        return RecentSearch(
            id: entry.id,
            kind: entry.kind,
            text: entry.text,
            subtitle: entry.subtitle ?? existing.subtitle,
            profileID: entry.profileID ?? existing.profileID,
            avatarURL: entry.avatarURL ?? existing.avatarURL,
            searchedAtMS: entry.searchedAtMS
        )
    }

    /// Records a submitted query. No-op for a blank one.
    @discardableResult
    public func recordQuery(_ text: String) -> RecentSearch? {
        guard let entry = RecentSearch.query(text, searchedAtMS: now()) else { return nil }
        record(entry)
        return entry
    }

    /// Records a person the viewer opened. No-op when there is nothing to
    /// route back to.
    @discardableResult
    public func recordProfile(
        id: String,
        displayName: String,
        handle: String,
        avatarURL: String? = nil
    ) -> RecentSearch? {
        guard let entry = RecentSearch.profile(
            id: id, displayName: displayName, handle: handle,
            avatarURL: avatarURL, searchedAtMS: now()
        ) else { return nil }
        record(entry)
        return entry
    }

    /// Removes one entry — the row's ✕.
    public func remove(id: RecentSearch.ID) {
        let changed: Bool = lock.withLock {
            var entries = read()
            let before = entries.count
            entries.removeAll { $0.id == id }
            guard entries.count != before else { return false }
            write(entries)
            return true
        }
        // Silent when the id wasn't there: a no-op is not a change, and
        // firing anyway would make every host re-render for nothing.
        if changed { onChange?() }
    }

    /// Clears the whole history — the section header's "Clear all".
    public func clear() {
        lock.withLock { defaults.removeObject(forKey: Self.key) }
        onChange?()
    }

    // MARK: - Display window

    /// What a collapsed or expanded Recent section shows.
    public struct Window: Equatable, Sendable {
        /// The rows to render, in order.
        public let rows: [RecentSearch]
        /// How many are held back. Zero when everything is on screen.
        public let hiddenCount: Int
        /// Whether the section ends in a "See more" row.
        public var showsMoreRow: Bool { hiddenCount > 0 }
    }

    /// Slices a history into what the section actually renders.
    ///
    /// Pure and static — it takes the entries rather than reading them — so the
    /// expansion rule is testable on its own and a view model can compute a
    /// window for a list it is holding mid-animation without touching disk.
    ///
    /// ⚠️ **Expanded shows everything, and "everything" is at most
    /// `storageLimit`.** There is no second page: the cap on what is kept is
    /// what bounds the expanded list, so "See more" reveals the rest exactly
    /// once and cannot lead to a row that reveals more again.
    public static func window(
        over entries: [RecentSearch],
        expanded: Bool,
        collapsedLimit: Int = RecentSearchStore.collapsedLimit
    ) -> Window {
        guard !expanded else { return Window(rows: entries, hiddenCount: 0) }
        let limit = max(0, collapsedLimit)
        guard entries.count > limit else { return Window(rows: entries, hiddenCount: 0) }
        return Window(rows: Array(entries.prefix(limit)), hiddenCount: entries.count - limit)
    }

    // MARK: - Persistence

    /// Decodes entry-by-entry, dropping any that fail.
    ///
    /// ⚠️ Not a whole-blob `try?`. `RecentSearch.Kind` exists so a later
    /// version can write a case this one has never heard of, and an
    /// all-or-nothing decode would let one such row delete the viewer's entire
    /// history on downgrade. One unreadable row costs one row.
    private func read() -> [RecentSearch] {
        guard let data = defaults.data(forKey: Self.key),
              let elements = try? JSONDecoder().decode([LossyEntry].self, from: data)
        else { return [] }
        return elements.compactMap(\.value)
    }

    private func write(_ entries: [RecentSearch]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.key)
    }

    /// Decodes a `RecentSearch`, or nothing, without failing its container.
    private struct LossyEntry: Decodable {
        let value: RecentSearch?

        init(from decoder: any Decoder) throws {
            value = try? RecentSearch(from: decoder)
        }
    }
}
