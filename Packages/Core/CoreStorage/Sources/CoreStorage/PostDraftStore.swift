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

    private let file: CodableFileStore<[PostDraft]>
    public private(set) var drafts: [PostDraft]

    /// `name` is the file the drafts live in; the default is the app's one
    /// list. A test passes its own, so it never reads the app's drafts.
    public init(name: String = "post-drafts") {
        file = CodableFileStore(name: name)
        drafts = (try? file.load()) ?? []
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
