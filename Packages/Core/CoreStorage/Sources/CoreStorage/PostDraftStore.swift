import Foundation

/// A post the viewer started and kept for later.
public struct PostDraft: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let text: String
    /// When it was last saved — the drafts list's second line.
    public let updatedAtMS: Int64

    public init(id: String = UUID().uuidString, text: String, updatedAtMS: Int64) {
        self.id = id
        self.text = text
        self.updatedAtMS = updatedAtMS
    }
}

/// The viewer's drafts, on this device, newest first.
///
/// ⚠️ LOCAL ON PURPOSE. post.v1 has a draft state of its own — `CreatePost`
/// makes one and `PublishPost` promotes it — but a server draft is already a
/// POST: it has an id, an author and a place in that author's records before
/// anyone has decided to publish it. A half-written thought the viewer set
/// aside is not that, and it should not cost a round trip or outlive the
/// device it was written on without being asked to.
///
/// Order is position in the stored array, newest at index 0 — the same rule
/// `RecentSearchStore` follows, for the same reason: a clock that moved does
/// not reorder the list.
@MainActor
public final class PostDraftStore {
    /// Posted after every change, with this store as the object.
    public static let didChangeNotification = Notification.Name("cn.wynn.core-platform-ios.PostDraftStore.didChange")

    private let name: String
    /// Whose drafts: the active profile's (`StorageScope`), one file each.
    private let scope: StorageScope
    private var file: CodableFileStore<[PostDraft]>
    public private(set) var drafts: [PostDraft]
    private var scopeObserver: NSObjectProtocol?

    /// `name` is the file the drafts live in; the default is the app's one
    /// list. A test passes its own, so it never reads the app's drafts.
    public init(name: String = "post-drafts", scope: StorageScope = .shared) {
        self.name = name
        self.scope = scope
        file = CodableFileStore(name: Self.fileName(name, scope: scope))
        drafts = Self.load(file, adoptingLegacy: name, scope: scope)
        // Another profile, another list: re-read when the viewer changes.
        scopeObserver = NotificationCenter.default.addObserver(
            forName: StorageScope.didChangeNotification, object: scope, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    /// The scoped file name — `:` kept out of file names.
    private static func fileName(_ name: String, scope: StorageScope) -> String {
        scope.profileKey(name).replacingOccurrences(of: ":", with: "_")
    }

    /// The scope's drafts — and, the first time a member's profile reads
    /// them, the unscoped file written before drafts were scoped
    /// (`StorageScope`'s adoption rule).
    private static func load(
        _ file: CodableFileStore<[PostDraft]>, adoptingLegacy name: String, scope: StorageScope
    ) -> [PostDraft] {
        if let drafts = try? file.load() { return drafts }
        guard case .member(_, _?) = scope.owner else { return [] }
        let legacy = CodableFileStore<[PostDraft]>(name: name)
        guard let drafts = try? legacy.load() else { return [] }
        try? file.save(drafts)
        try? legacy.clear()
        return drafts
    }

    private func reload() {
        file = CodableFileStore(name: Self.fileName(name, scope: scope))
        drafts = Self.load(file, adoptingLegacy: name, scope: scope)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// Saves `text` as a draft — as a NEW one, or in place of `id` when the
    /// viewer was editing that draft — and moves it to the top. Blank text is
    /// refused: an empty draft is a row with nothing to go back to.
    @discardableResult
    public func save(_ text: String, replacing id: String? = nil, now: Date = Date()) -> PostDraft? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let draft = PostDraft(
            id: id ?? UUID().uuidString,
            text: trimmed,
            updatedAtMS: Int64(now.timeIntervalSince1970 * 1000)
        )
        drafts.removeAll { $0.id == draft.id }
        drafts.insert(draft, at: 0)
        persist()
        return draft
    }

    public func delete(_ id: String) {
        guard drafts.contains(where: { $0.id == id }) else { return }
        drafts.removeAll { $0.id == id }
        persist()
    }

    public func draft(_ id: String) -> PostDraft? {
        drafts.first { $0.id == id }
    }

    /// Best-effort, like every snapshot file here: a failed write leaves the
    /// list in memory for this session, which is still the list on screen.
    private func persist() {
        try? file.save(drafts)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
