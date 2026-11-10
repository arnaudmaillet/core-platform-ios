import Foundation

/// A post the viewer started and kept for later.
public struct PostDraft: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let text: String
    /// When it was last saved — the drafts list's second line.
    public let updatedAtMS: Int64
    /// The voice the post starts with, when it has one (#2209). A draft saved
    /// before voices decodes with none.
    public let voice: Voice?

    /// A kept take: its file, in the store's own folder, and what its paused
    /// bar shows without opening it.
    public struct Voice: Codable, Equatable, Sendable {
        /// The file's name in `PostDraftStore.voiceDirectory`.
        public let fileName: String
        public let duration: TimeInterval
        /// The take's waveform levels, as recorded.
        public let waveform: [UInt8]

        public init(fileName: String, duration: TimeInterval, waveform: [UInt8]) {
            self.fileName = fileName
            self.duration = duration
            self.waveform = waveform
        }
    }

    public init(id: String = UUID().uuidString, text: String, updatedAtMS: Int64, voice: Voice? = nil) {
        self.id = id
        self.text = text
        self.updatedAtMS = updatedAtMS
        self.voice = voice
    }
}

/// A take handed to `PostDraftStore.save`: where it is now, and its metadata.
/// The store copies the file into its own folder unless it is already there.
public struct PostDraftVoiceTake: Equatable, Sendable {
    public let fileURL: URL
    public let duration: TimeInterval
    public let waveform: [UInt8]

    public init(fileURL: URL, duration: TimeInterval, waveform: [UInt8]) {
        self.fileURL = fileURL
        self.duration = duration
        self.waveform = waveform
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
    /// Where the drafts' voices live (#2209): one file per draft that has one,
    /// removed with it. Every profile's in the same folder; the names are
    /// unique, and only the list that names a file removes it.
    public let voiceDirectory: URL

    /// `name` is the file the drafts live in; the default is the app's one
    /// list. A test passes its own, so it never reads the app's drafts.
    public init(name: String = "post-drafts", scope: StorageScope = .shared) {
        self.name = name
        self.scope = scope
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        voiceDirectory = base.appending(path: "PostDraftVoices/\(name)", directoryHint: .isDirectory)
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
    /// viewer was editing that draft — and moves it to the top. A draft is
    /// words, a voice, or both (#2209): with neither it is refused, since an
    /// empty draft is a row with nothing to go back to.
    ///
    /// `voice` is the take the draft keeps, copied into `voiceDirectory`
    /// unless it is that draft's own file already. Without one, a draft that
    /// had a voice loses it, file and all — the caller always says what the
    /// draft holds now.
    @discardableResult
    public func save(
        _ text: String, voice: PostDraftVoiceTake? = nil, replacing id: String? = nil, now: Date = Date()
    ) -> PostDraft? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || voice != nil else { return nil }
        let previous = id.flatMap { draft($0) }?.voice
        let kept = voice.flatMap { keep($0, previous: previous) }
        // A voice that couldn't be kept leaves only the words — and nothing,
        // if there were none.
        guard !trimmed.isEmpty || kept != nil else { return nil }
        if let previous, previous.fileName != kept?.fileName { removeVoice(previous) }
        let draft = PostDraft(
            id: id ?? UUID().uuidString,
            text: trimmed,
            updatedAtMS: Int64(now.timeIntervalSince1970 * 1000),
            voice: kept
        )
        drafts.removeAll { $0.id == draft.id }
        drafts.insert(draft, at: 0)
        persist()
        return draft
    }

    public func delete(_ id: String) {
        guard let gone = draft(id) else { return }
        drafts.removeAll { $0.id == id }
        if let voice = gone.voice { removeVoice(voice) }
        persist()
    }

    /// The file a draft's voice is kept in.
    public func voiceURL(_ voice: PostDraft.Voice) -> URL {
        voiceDirectory.appending(path: voice.fileName, directoryHint: .notDirectory)
    }

    /// The take, as the draft's own file: the draft's file already when it is
    /// that one, a copy in `voiceDirectory` otherwise. Nil when the copy fails.
    private func keep(_ take: PostDraftVoiceTake, previous: PostDraft.Voice?) -> PostDraft.Voice? {
        if let previous, take.fileURL.standardizedFileURL == voiceURL(previous).standardizedFileURL {
            return PostDraft.Voice(fileName: previous.fileName, duration: take.duration, waveform: take.waveform)
        }
        let fileManager = FileManager.default
        let ext = take.fileURL.pathExtension.isEmpty ? "m4a" : take.fileURL.pathExtension
        let fileName = UUID().uuidString + "." + ext
        do {
            try fileManager.createDirectory(at: voiceDirectory, withIntermediateDirectories: true)
            try fileManager.copyItem(at: take.fileURL, to: voiceDirectory.appending(path: fileName))
        } catch {
            return nil
        }
        return PostDraft.Voice(fileName: fileName, duration: take.duration, waveform: take.waveform)
    }

    private func removeVoice(_ voice: PostDraft.Voice) {
        try? FileManager.default.removeItem(at: voiceURL(voice))
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
