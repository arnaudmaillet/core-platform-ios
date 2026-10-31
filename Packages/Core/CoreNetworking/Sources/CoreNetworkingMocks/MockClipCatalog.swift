import Foundation

/// The mock corpus's REAL video clips.
///
/// Imported by `Scripts/import-mock-clips.py` into `Resources/MockClips`,
/// re-encoded small enough to commit (HEVC ≤720p, ≤25 s; sounds AAC ≤30 s),
/// and listed in `clips.json`.
///
/// ⚠️ TWO KINDS (the owner, 2026-10-31):
/// - **The clips posts draw from** (`postClips`): the owner's "media 2"
///   videos, each heard with its OWN audio, from its player. They have no
///   sound file, and their sound is never lent (`soundIsUnique`).
/// - **The retired clips**, the corpus's first: no post draws them any more.
///   Their sounds stay, and photo and text posts keep borrowing them. A few
///   keep their video too, the ones the animated avatars and the video
///   banners read (`--keep-video`).
///
/// The dataset addresses a clip as `mock://video/<clip-id>?w=&h=` — still a
/// `mock://video/` URL, so every rule that routes on it (the attachment's MIME,
/// the grid's video badge, the map's pin face) is unchanged — and the app's
/// video source asks `fileURL(forVideo:)` before synthesizing anything. A URL
/// that is not a clip keeps the synthesized placeholder.
public struct MockClipCatalog: Sendable {
    public struct Clip: Sendable, Equatable, Decodable {
        public let id: String
        /// The ENCODED size, which is what pre-layout must be told: a declared
        /// size the file does not have shows up as a crop.
        public let width: Int
        public let height: Int
        public let duration: Double
        /// The full sound, often longer than the clip it plays under.
        public let soundDuration: Double
        /// Nil for the author's own "original sound".
        public let soundTitle: String?
        public let soundArtist: String?
        /// The clip's sound belongs to its own post alone (the owner,
        /// 2026-10-16: `--unique=` in the import): never lent to another post.
        public let soundIsUnique: Bool?
        /// No post draws this clip any more (the owner's "media 2",
        /// 2026-10-31): kept for its sound, its poster and — for a few — the
        /// avatars and banners that read its video.
        public let retired: Bool?

        public var lendsItsSound: Bool { soundIsUnique != true }
        public var isRetired: Bool { retired == true }
    }

    public static let shared = MockClipCatalog(bundle: .module)

    public let clips: [Clip]
    /// The clips posts draw from, in order: every clip but the retired ones.
    public let postClips: [Clip]
    private let directory: URL?

    init(bundle: Bundle) {
        let directory = bundle.url(forResource: "MockClips", withExtension: nil)
        self.directory = directory
        guard let manifest = directory?.appendingPathComponent("clips.json"),
              let data = try? Data(contentsOf: manifest),
              let clips = try? JSONDecoder().decode([Clip].self, from: data)
        else {
            self.clips = []
            self.postClips = []
            return
        }
        self.clips = clips
        self.postClips = clips.filter { !$0.isRetired }
    }

    /// The clip for a dataset slot: every post clip once, in order, then
    /// round again — one clip may be several posts' (the owner, 2026-10-31),
    /// each post with its own id, and a repeat carries the clip's own sound
    /// with it. Never a retired clip. Nil only when the resources are
    /// missing, and the dataset then synthesizes as before.
    public func clip(forSlot slot: Int) -> Clip? {
        guard !postClips.isEmpty else { return nil }
        return postClips[((slot % postClips.count) + postClips.count) % postClips.count]
    }

    /// The clip the animated avatar of the author at `index` is cut from: a
    /// RETIRED clip, the index round them.
    ///
    /// ⚠️ NEVER A POST'S CLIP (the owner, 2026-10-31: avatars keep the old
    /// media). The avatars went round every baked sheet, so importing the
    /// posts' new clips would have given every animated author another face.
    /// The retired clips are the ones they went round before, in the same
    /// order; the ones read keep their video (`--keep-video`).
    public func avatarClip(forSheetAvatar index: Int) -> Clip? {
        let retired = clips.filter(\.isRetired)
        guard !retired.isEmpty else { return nil }
        return retired[((index % retired.count) + retired.count) % retired.count]
    }

    /// The clips whose sound another post may borrow — every clip but the
    /// ones whose sound is their post's alone: the retired clips' sounds, in
    /// the order they always had, so a borrowing post keeps its sound.
    public var borrowableClips: [Clip] { clips.filter(\.lendsItsSound) }

    /// The borrowable clip for a slot, cycling through the borrowable ones.
    public func borrowableClip(forSlot slot: Int) -> Clip? {
        let pool = borrowableClips
        guard !pool.isEmpty else { return nil }
        return pool[((slot % pool.count) + pool.count) % pool.count]
    }

    /// The dataset's media tuple for a slot: the clip's URL and its encoded size.
    public func media(forSlot slot: Int) -> (url: String, width: Int, height: Int)? {
        clip(forSlot: slot).map { ("mock://video/\($0.id)?w=\($0.width)&h=\($0.height)", $0.width, $0.height) }
    }

    /// The clip a `mock://video/<clip-id>` URL names, if it names one.
    public func clip(for url: URL) -> Clip? {
        guard url.scheme == "mock", url.host == "video" else { return nil }
        let id = url.lastPathComponent
        return clips.first { $0.id == id }
    }

    /// The clip named `id`.
    public func clip(id: String) -> Clip? {
        clips.first { $0.id == id }
    }

    /// The bundled full sound of the clip named `id`.
    public func soundFileURL(clipID id: String) -> URL? {
        file(named: "\(id)-sound.m4a")
    }

    /// The bundled video file of the clip named `id`.
    public func videoFileURL(clipID id: String) -> URL? {
        file(named: "\(id).mp4")
    }

    /// The poster of the clip named `id`.
    public func posterFileURL(clipID id: String) -> URL? {
        file(named: "\(id).jpg")
    }

    /// The bundled video file behind a clip URL.
    public func fileURL(forVideo url: URL) -> URL? {
        clip(for: url).flatMap { file(named: "\($0.id).mp4") }
    }

    /// The bundled full sound behind a clip URL.
    public func soundFileURL(forVideo url: URL) -> URL? {
        clip(for: url).flatMap { file(named: "\($0.id)-sound.m4a") }
    }

    /// A small poster frame of the clip, for artwork.
    public func posterFileURL(forVideo url: URL) -> URL? {
        clip(for: url).flatMap { file(named: "\($0.id).jpg") }
    }

    private func file(named name: String) -> URL? {
        guard let url = directory?.appendingPathComponent(name),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}
