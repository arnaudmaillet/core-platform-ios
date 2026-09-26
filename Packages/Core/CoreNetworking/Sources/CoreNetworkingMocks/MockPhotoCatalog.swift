import Foundation

/// The mock corpus's REAL photographs, grouped in galleries.
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
            self.photos = []
            return
        }
        self.galleries = galleries.filter { !$0.photos.isEmpty }
        self.photos = self.galleries.flatMap(\.photos)
    }

    /// The photo for a dataset slot, cycling through EVERY photo of every
    /// gallery. Nil only when the resources are missing.
    public func photo(forSlot slot: Int) -> Photo? {
        guard !photos.isEmpty else { return nil }
        return photos[Self.wrap(slot, photos.count)]
    }

    /// The gallery for a dataset slot, cycling through the galleries.
    public func gallery(forSlot slot: Int) -> Gallery? {
        guard !galleries.isEmpty else { return nil }
        return galleries[Self.wrap(slot, galleries.count)]
    }

    /// Page `page` of the gallery at `slot`, cycling WITHIN that gallery when
    /// a collection has more pages than the gallery has photos — so every
    /// page of one collection comes from one shoot.
    public func photo(inGalleryForSlot slot: Int, page: Int) -> Photo? {
        gallery(forSlot: slot).map { $0.photos[Self.wrap(page, $0.photos.count)] }
    }

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
