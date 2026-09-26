import Foundation

/// The mock corpus's REAL video clips: short videos with their own soundtrack,
/// each paired with the full sound the post is set to.
///
/// Imported by `Scripts/import-mock-clips.py` into `Resources/MockClips`,
/// re-encoded small enough to commit (HEVC 540p, ≤25 s; sounds AAC ≤30 s),
/// and listed in `clips.json`.
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
    }

    public static let shared = MockClipCatalog(bundle: .module)

    public let clips: [Clip]
    private let directory: URL?

    init(bundle: Bundle) {
        let directory = bundle.url(forResource: "MockClips", withExtension: nil)
        self.directory = directory
        guard let manifest = directory?.appendingPathComponent("clips.json"),
              let data = try? Data(contentsOf: manifest),
              let clips = try? JSONDecoder().decode([Clip].self, from: data)
        else {
            self.clips = []
            return
        }
        self.clips = clips
    }

    /// The clip for a dataset slot, cycling through the catalog. Nil only when
    /// the resources are missing, and the dataset then synthesizes as before.
    public func clip(forSlot slot: Int) -> Clip? {
        guard !clips.isEmpty else { return nil }
        return clips[((slot % clips.count) + clips.count) % clips.count]
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
