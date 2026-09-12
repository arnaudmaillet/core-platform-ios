import Photos
import UIKit

/// The real library: Photos.
///
/// ⚠️ **A CUSTOM GRID IS WHAT COSTS THE PERMISSION.** `PHPickerViewController`
/// runs out of process and needs neither an authorization request nor a usage
/// string — but it also draws its own chrome, so it cannot number a selection,
/// carry a tray, or put album pills in a toolbar. Reading `PHAsset` ourselves is
/// what buys that screen, and `NSPhotoLibraryUsageDescription` in `App/Info.plist`
/// is the price. Nothing here writes to the library.
final class PhotosMediaLibrary: MediaLibraryReading {
    private let images = PHCachingImageManager()

    /// The collections the last `albums()` found, so an album id resolves
    /// without fetching the whole list again.
    private var collectionsByID: [String: PHAssetCollection] = [:]

    /// Every asset seen so far, because a thumbnail request needs the `PHAsset`
    /// and not its identifier.
    ///
    /// ⚠️ IT ACCUMULATES ACROSS ALBUMS ON PURPOSE. A selection made in "Recents"
    /// keeps its thumbnails in the tray after the viewer switches to "Videos",
    /// and clearing this on each album change would blank exactly those. The
    /// entries are lightweight handles into Photos, not images.
    private var assetsByID: [String: PHAsset] = [:]

    /// Photos and videos, newest first — the one shape every fetch here wants.
    private static var contents: PHFetchOptions {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "mediaType == %d || mediaType == %d",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return options
    }

    /// The smart albums offered, in the order the selector shows them.
    ///
    /// Curated rather than "every smart album Photos has": the rest are hidden
    /// albums, recently deleted, or lists a post has no use for. The fallback
    /// title is only reached when Photos hands back no localized one.
    private static let smartAlbums: [(subtype: PHAssetCollectionSubtype, fallbackTitle: String)] = [
        (.smartAlbumUserLibrary, "Recents"),
        (.smartAlbumFavorites, "Favorites"),
        (.smartAlbumVideos, "Videos"),
        (.smartAlbumSelfPortraits, "Selfies"),
        (.smartAlbumScreenshots, "Screenshots"),
        (.smartAlbumLivePhotos, "Live Photos"),
        (.smartAlbumPanoramas, "Panoramas"),
        (.smartAlbumBursts, "Bursts")
    ]

    // MARK: - Access

    var access: MediaLibraryAccess {
        Self.access(from: PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAccess() async -> MediaLibraryAccess {
        let status = await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
        return Self.access(from: status)
    }

    private static func access(from status: PHAuthorizationStatus) -> MediaLibraryAccess {
        switch status {
        case .notDetermined: .undetermined
        case .authorized: .granted
        case .limited: .limited
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    // MARK: - Contents

    func albums() async -> [MediaLibraryAlbum] {
        var found: [MediaLibraryAlbum] = []
        var collections: [String: PHAssetCollection] = [:]

        func offer(_ collection: PHAssetCollection, fallbackTitle: String?) {
            let count = PHAsset.fetchAssets(in: collection, options: Self.contents).count
            // An empty album is left out: a pill reading "(0)" offers nothing,
            // and Photos ships several that most libraries never fill.
            guard count > 0 else { return }
            let id = collection.localIdentifier
            guard collections[id] == nil else { return }
            collections[id] = collection
            found.append(
                MediaLibraryAlbum(
                    id: id,
                    title: collection.localizedTitle ?? fallbackTitle ?? "Album",
                    count: count
                )
            )
        }

        for smart in Self.smartAlbums {
            let fetched = PHAssetCollection.fetchAssetCollections(
                with: .smartAlbum, subtype: smart.subtype, options: nil
            )
            for index in 0..<fetched.count {
                offer(fetched.object(at: index), fallbackTitle: smart.fallbackTitle)
            }
        }

        let userAlbums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        for index in 0..<userAlbums.count {
            offer(userAlbums.object(at: index), fallbackTitle: nil)
        }

        collectionsByID = collections
        return found
    }

    func items(in album: MediaLibraryAlbum.ID) async -> [MediaLibraryItem] {
        guard let collection = collectionsByID[album] else { return [] }
        let assets = PHAsset.fetchAssets(in: collection, options: Self.contents)
        var items: [MediaLibraryItem] = []
        items.reserveCapacity(assets.count)
        for index in 0..<assets.count {
            let asset = assets.object(at: index)
            assetsByID[asset.localIdentifier] = asset
            items.append(
                MediaLibraryItem(
                    id: asset.localIdentifier,
                    kind: asset.mediaType == .video ? .video(duration: asset.duration) : .photo
                )
            )
        }
        return items
    }

    // MARK: - Thumbnails

    func thumbnail(for item: MediaLibraryItem.ID, size: CGSize) async -> UIImage? {
        guard let asset = assetsByID[item] else { return nil }
        let options = PHImageRequestOptions()
        // An asset that lives in iCloud rather than on the device is still one
        // of the viewer's photos, and a grid that skipped those would look like
        // a library with holes in it.
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast
        // ⚠️ ONE CALLBACK, DELIBERATELY. `.opportunistic` reports twice — a
        // degraded image, then the real one — and a checked continuation
        // resumed a second time traps the process. `.highQualityFormat` reports
        // once.
        options.deliveryMode = .highQualityFormat

        // The box is `PickedImage`, this package's own: a `UIImage` is not
        // `Sendable`, and it is already the way an image crosses out of UIKit
        // here on its way to the composer.
        let boxed: PickedImage? = await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            images.requestImage(
                for: asset,
                targetSize: Self.pixels(for: size),
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                once.run { continuation.resume(returning: image.map(PickedImage.init)) }
            }
        }
        return boxed?.image
    }

    func startCaching(_ items: [MediaLibraryItem.ID], size: CGSize) {
        let assets = items.compactMap { assetsByID[$0] }
        guard !assets.isEmpty else { return }
        images.startCachingImages(
            for: assets, targetSize: Self.pixels(for: size), contentMode: .aspectFill, options: nil
        )
    }

    func stopCaching(_ items: [MediaLibraryItem.ID], size: CGSize) {
        let assets = items.compactMap { assetsByID[$0] }
        guard !assets.isEmpty else { return }
        images.stopCachingImages(
            for: assets, targetSize: Self.pixels(for: size), contentMode: .aspectFill, options: nil
        )
    }

    /// Photos measures a target in PIXELS; the grid measures its cells in
    /// points. Asking in points on a 3x screen returns a thumbnail a third of
    /// the size it is drawn at, which reads as a blurred grid.
    private static func pixels(for size: CGSize) -> CGSize {
        let scale = UITraitCollection.current.displayScale
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

/// Resumes a continuation at most once.
///
/// The belt to `.highQualityFormat`'s brace: Photos has more than one way to
/// report a request it gave up on, and a trap inside a thumbnail is not worth
/// the five lines this saves.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var hasRun = false

    func run(_ body: () -> Void) {
        lock.lock()
        let shouldRun = !hasRun
        hasRun = true
        lock.unlock()
        guard shouldRun else { return }
        body()
    }
}
