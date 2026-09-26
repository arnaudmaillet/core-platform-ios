import Foundation

/// Songs the mock corpus sets its photo, collection and text posts to — the
/// sounds that are not a clip's own.
///
/// Imported by `Scripts/import-mock-songs.py` into `Resources/MockSongs`
/// (AAC, ≤30 s) and listed in `songs.json`.
public struct MockSongCatalog: Sendable {
    public struct Song: Sendable, Equatable, Decodable {
        public let id: String
        public let title: String
        public let artist: String?
        public let duration: Double
    }

    public static let shared = MockSongCatalog(bundle: .module)

    public let songs: [Song]
    private let directory: URL?

    init(bundle: Bundle) {
        let directory = bundle.url(forResource: "MockSongs", withExtension: nil)
        self.directory = directory
        guard let manifest = directory?.appendingPathComponent("songs.json"),
              let data = try? Data(contentsOf: manifest),
              let songs = try? JSONDecoder().decode([Song].self, from: data)
        else {
            self.songs = []
            return
        }
        self.songs = songs
    }

    /// The song for a slot, cycling through the catalog; nil when it is empty.
    public func song(forSlot slot: Int) -> Song? {
        guard !songs.isEmpty else { return nil }
        return songs[((slot % songs.count) + songs.count) % songs.count]
    }

    public func song(id: String) -> Song? {
        songs.first { $0.id == id }
    }

    /// The bundled file of the song named `id`.
    public func fileURL(songID id: String) -> URL? {
        guard let url = directory?.appendingPathComponent("\(id).m4a"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}
