import Foundation

/// The mock corpus's REAL photographs, grouped in galleries.
///
/// ⚠️ TWO POOLS (the owner, 2026-10-31). POSTS draw from `posts`, the
/// photographs of the owner's "media 2" folder (`Scripts/import-mock-photos.py
/// --posts=`). The galleries and singles are no post's any more: they are kept
/// because the AVATARS and so the banners read them (`avatarPhoto`), and an
/// author keeps the face they had.
///
/// Imported by `Scripts/import-mock-photos.py` into `Resources/MockPhotos`
/// (long side ≤ 1440 px, JPEG, metadata stripped) and listed in `photos.json`.
/// A gallery is one source folder: the photos of one shoot, which is what a
/// collection post's pages are made of.
///
/// The dataset addresses a photo as `mock://photo/<photo-id>?w=&h=`, with the
/// photo's ENCODED size — pre-layout trusts the declared size and crops to it —
/// and the app's image fetcher asks `fileURL(forPhoto:)` before synthesizing
/// anything. A `mock://` URL that is not a photo keeps the synthesized
/// placeholder.
public struct MockPhotoCatalog: Sendable {
    public struct Photo: Sendable, Equatable, Decodable {
        public let id: String
        public let file: String
        /// The ENCODED size, which is what pre-layout must be told.
        public let width: Int
        public let height: Int

        /// The dataset's media tuple for this photo.
        public var media: (url: String, width: Int, height: Int) {
            ("\(MockPhotoCatalog.scheme)\(id)?w=\(width)&h=\(height)", width, height)
        }
    }

    public struct Gallery: Sendable, Equatable, Decodable {
        public let id: String
        public let photos: [Photo]
    }

    /// The prefix every catalog photo URL carries.
    public static let scheme = "mock://photo/"

    public static let shared = MockPhotoCatalog(bundle: .module)

    public let galleries: [Gallery]
    /// Photographs that belong to no gallery — the `singles` folder of an
    /// import — each one a single-photo post's picture.
    public let singles: [Photo]
    /// The id of the manifest entry holding `singles`.
    public static let singlesID = "singles"
    /// The photographs posts draw from — single photos and collection pages.
    public let posts: [Photo]
    /// The id of the manifest entry holding `posts`.
    public static let postsID = "posts"
    /// Every photo of every gallery, in gallery order.
    public let photos: [Photo]
    private let directory: URL?

    init(bundle: Bundle) {
        let directory = bundle.url(forResource: "MockPhotos", withExtension: nil)
        self.directory = directory
        guard let manifest = directory?.appendingPathComponent("photos.json"),
              let data = try? Data(contentsOf: manifest),
              let galleries = try? JSONDecoder().decode([Gallery].self, from: data)
        else {
            self.galleries = []
            self.singles = []
            self.posts = []
            self.photos = []
            return
        }
        self.galleries = galleries.filter { !$0.photos.isEmpty && ![Self.singlesID, Self.postsID].contains($0.id) }
        self.singles = galleries.first { $0.id == Self.singlesID }?.photos ?? []
        self.posts = galleries.first { $0.id == Self.postsID }?.photos ?? []
        self.photos = self.galleries.flatMap(\.photos) + singles + posts
    }

    /// The picture of a SINGLE-photo post, `ordinal` counting those posts
    /// across the whole mock world: `posts` in order, each once, then round
    /// again — one picture may be several posts' (the owner, 2026-10-31),
    /// each post with its own id.
    public func singlePhoto(forOrdinal ordinal: Int) -> Photo? {
        guard !posts.isEmpty else { return nil }
        return posts[Self.wrap(ordinal, posts.count)]
    }

    /// The pool avatars are drawn from: the singles, then gallery pages past
    /// their heads — the pool posts drew from before "media 2", kept as it was
    /// so every author keeps their picture.
    private var singlePool: [Photo] { singles + galleries.flatMap { $0.photos.dropFirst() } }

    /// The picture of an AVATAR — and so of a profile's banner — `ordinal`
    /// counting avatars of one orientation (#1314).
    ///
    /// ⚠️ NEVER FROM `posts`: avatars and banners keep the old photographs
    /// (the owner, 2026-10-31).
    ///
    /// From the other end of the old posts' pool. Avatars used to stride over
    /// every photo, so a dozen authors wore a picture that was also a post's
    /// (the owner, 2026-10-17: "éviter le plus possible d'avoir des
    /// doublons"). Posts spend the pool from its head (the 46 singles first)
    /// and avatars from its tail, landscape and portrait in two disjoint
    /// runs, so the two meet only once the whole pool is spent. A landscape
    /// avatar gives a band banner, the rest a poster.
    public func avatarPhoto(forOrdinal ordinal: Int, landscape: Bool) -> Photo? {
        let tail = singlePool.reversed()
        let run = tail.filter { ($0.width > $0.height) == landscape }
        let pool = run.isEmpty ? Array(tail) : run
        guard !pool.isEmpty else { return nil }
        return pool[Self.wrap(ordinal, pool.count)]
    }

    /// The photo for a dataset slot, cycling through EVERY photo of every
    /// gallery. Nil only when the resources are missing.
    public func photo(forSlot slot: Int) -> Photo? {
        guard !photos.isEmpty else { return nil }
        return photos[Self.wrap(slot, photos.count)]
    }

    /// Page `page` of the collection at `slot`: a run of `posts` starting
    /// `collectionStride` pictures apart per collection, so two collections
    /// open on different pictures. The few collections the corpus keeps are
    /// fixtures for the carousel (the owner, 2026-10-31: few carousels), and
    /// "media 2" has no shoots to make them of.
    public func photo(inGalleryForSlot slot: Int, page: Int) -> Photo? {
        guard !posts.isEmpty else { return nil }
        return posts[Self.wrap(slot * Self.collectionStride + page, posts.count)]
    }

    /// How far apart two collections start in `posts`.
    static let collectionStride = 5

    /// The photo a `mock://photo/<photo-id>` URL names, if it names one.
    public func photo(for url: URL) -> Photo? {
        guard url.scheme == "mock", url.host == "photo" else { return nil }
        let id = url.lastPathComponent
        return photos.first { $0.id == id }
    }

    /// The gallery a photo belongs to.
    public func gallery(containing photo: Photo) -> Gallery? {
        galleries.first { $0.photos.contains(photo) }
    }

    /// The bundled file behind a photo URL.
    public func fileURL(forPhoto url: URL) -> URL? {
        guard let photo = photo(for: url),
              let file = directory?.appendingPathComponent(photo.file),
              FileManager.default.fileExists(atPath: file.path) else { return nil }
        return file
    }

    private static func wrap(_ value: Int, _ count: Int) -> Int {
        ((value % count) + count) % count
    }
}
