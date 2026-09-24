// `AVURLAsset`, `AVAssetExportPresetPassthrough` — what a picked video is
// flattened into a file with. Photos re-exports neither.
import AVFoundation
import Photos
// ⚠️ `presentLimitedLibraryPicker(from:)` IS PhotosUI, NOT Photos. It reads like
// a `PHPhotoLibrary` method and is spelled like one, but the framework that
// declares that extension is PhotosUI — importing only Photos fails with "value
// of type 'PHPhotoLibrary' has no member", which sounds like a wrong API rather
// than a missing import.
import PhotosUI
import UIKit

/// The real library: Photos.
///
/// ⚠️ **A CUSTOM GRID IS WHAT COSTS THE PERMISSION.** `PHPickerViewController`
/// runs out of process and needs neither an authorization request nor a usage
/// string — but it also draws its own chrome, so it cannot number a selection,
/// carry a tray, or put album pills in a toolbar. Reading `PHAsset` ourselves is
/// what buys that screen, and `NSPhotoLibraryUsageDescription` in `App/Info.plist`
/// is the price.
///
/// ⚠️ **THIS USED TO SAY "NOTHING HERE WRITES TO THE LIBRARY", AND THAT IS NO
/// LONGER TRUE IN DEBUG.** `albums()` first runs `DebugPhotoAlbumSeeder`, which
/// behind `-seed-photo-albums` CREATES albums and files existing assets into
/// them — the only way to get user albums onto a simulator. In release builds
/// the seeder does not exist and this type still only reads.
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
    nonisolated private static var contents: PHFetchOptions {
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
    nonisolated private static let smartAlbums: [(subtype: PHAssetCollectionSubtype, fallbackTitle: String)] = [
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

    /// ⚠️ **THE ONE PLACE THIS CALL BELONGS.** Widening a limited selection is a
    /// `Photos` affair, and this file is the only one in the feature that imports
    /// it. Adding photos here never leaves the app — Settings does, and asks the
    /// viewer to find their way back — which is why the notice offers this first.
    func presentLimitedPicker(from host: UIViewController) {
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: host)
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
        // ⚠️ A SIMULATOR HAS NO USER ALBUMS, so the branch below finds nothing
        // and the strip shows smart albums alone. Behind `-seed-photo-albums`
        // this makes a few first — see `DebugPhotoAlbumSeeder` for why no
        // command-line tool can do it.
        #if DEBUG
        await DebugPhotoAlbumSeeder.seedIfAsked()
        #endif
        let scan = await Task.detached(priority: .userInitiated) { Self.scanAlbums() }.value
        collectionsByID = scan.collections
        return scan.albums
    }

    func items(in album: MediaLibraryAlbum.ID) async -> [MediaLibraryItem] {
        guard let collection = collectionsByID[album] else { return [] }
        let handle = CollectionHandle(collection)
        let scan = await Task.detached(priority: .userInitiated) { Self.scanItems(in: handle.collection) }.value
        assetsByID.merge(scan.assets) { _, new in new }
        return scan.items
    }

    // MARK: - Enumeration, off the main actor

    /// ⚠️ **THE WALKS BELOW RUN IN A DETACHED TASK, AND THAT IS THE WHOLE
    /// POINT OF THEIR SHAPE (charter P4).** `albums()` fetches every asset of
    /// every album to count it, and `items(in:)` touches every asset of the
    /// one it opens; on a full device that is seconds, and it used to run on
    /// the main actor in the picker's presentation turn — `-presentation-budget`
    /// blamed `MediaPickerViewController` for 500 ms on a library of 26. Photos
    /// is safe to read from any queue and `PHObject`s are immutable, so the
    /// walk is a `nonisolated` function returning value types, and the handles
    /// it collected cross back in a box that says so. The protocol stays
    /// `@MainActor`: the map of handles and the thumbnail requests still live
    /// there, unchanged.
    ///
    /// ⚠️ **NOTHING HERE MAY BE A CLOSURE WRITTEN IN THIS TYPE'S ISOLATION.**
    /// A closure written inside a `@MainActor` type inherits its isolation and
    /// TRAPS when Photos calls it elsewhere (`videoFile(for:)` and
    /// `DebugPhotoAlbumSeeder` both paid for that); `static nonisolated` has
    /// no isolation to inherit.
    private struct AlbumScan: @unchecked Sendable {
        let albums: [MediaLibraryAlbum]
        let collections: [String: PHAssetCollection]
    }

    private struct ItemScan: @unchecked Sendable {
        let items: [MediaLibraryItem]
        let assets: [String: PHAsset]
    }

    private struct CollectionHandle: @unchecked Sendable {
        let collection: PHAssetCollection
        init(_ collection: PHAssetCollection) { self.collection = collection }
    }

    nonisolated private static func scanAlbums() -> AlbumScan {
        var found: [MediaLibraryAlbum] = []
        var collections: [String: PHAssetCollection] = [:]

        func offer(_ collection: PHAssetCollection, fallbackTitle: String?) {
            let count = PHAsset.fetchAssets(in: collection, options: contents).count
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

        for smart in smartAlbums {
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

        return AlbumScan(albums: found, collections: collections)
    }

    nonisolated private static func scanItems(in collection: PHAssetCollection) -> ItemScan {
        let fetched = PHAsset.fetchAssets(in: collection, options: contents)
        var items: [MediaLibraryItem] = []
        var assets: [String: PHAsset] = [:]
        items.reserveCapacity(fetched.count)
        for index in 0..<fetched.count {
            let asset = fetched.object(at: index)
            assets[asset.localIdentifier] = asset
            items.append(
                MediaLibraryItem(
                    id: asset.localIdentifier,
                    kind: asset.mediaType == .video ? .video(duration: asset.duration) : .photo
                )
            )
        }
        return ItemScan(items: items, assets: assets)
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
            ) { @Sendable image, _ in
                once.run { continuation.resume(returning: image.map(PickedImage.init)) }
            }
        }
        return boxed?.image
    }

    // MARK: - Video files

    /// ⚠️ **TWO ROUTES, AND THE FAST ONE IS NOT AN OPTIMISATION — IT IS THE
    /// COMMON CASE.** A clip recorded on this device is already a file, and
    /// `requestAVAsset` hands back an `AVURLAsset` pointing straight at it; the
    /// `.url` costs nothing and copies nothing. Exporting that would duplicate
    /// hundreds of megabytes into the temp directory for no reason.
    ///
    /// ⚠️ **THE SLOW ROUTE IS NOT A FALLBACK FOR ERRORS — IT IS FOR ASSETS THAT
    /// ARE NOT ONE FILE.** `requestAVAssetForVideo:` is typed `AVAsset *`, not
    /// `AVURLAsset *`, and the header promises nothing more. A composed asset
    /// has no single URL to take, so a passthrough export flattens it into one.
    /// Whether a slow-motion asset is such a composite is **unverified here** —
    /// widely repeated, never stated by Apple — which is exactly why this does
    /// not test for slo-mo and instead asks the only question that matters: did
    /// I get a URL, or do I have to make one?
    ///
    /// ⚠️ **NOTHING AVFOUNDATION CROSSES OUT OF THE RESULT HANDLER.** Photos
    /// calls it on an arbitrary queue, and measured under Swift 6 with
    /// `-emit-sil`: `AVAsset` is not `Sendable`, and `AVAssetExportSession`'s
    /// conformance is explicitly *unavailable*. So the asset is inspected, and
    /// the session is driven, **inside** the handler; only a `URL` is ever
    /// resumed. See `MediaLibraryReading.videoFile(for:)` for the full table.
    ///
    /// ⚠️ **AND THE HANDLER IS `@Sendable`, WITHOUT WHICH THIS TRAPPED THE
    /// PROCESS ON THE FIRST REAL CLIP IT EVER SAW.** Keeping AVFoundation inside
    /// the handler fixed the COMPILE error and left the runtime one standing:
    /// `MediaLibraryReading` is `@MainActor`, so a closure written here inherits
    /// main-actor isolation, and `PHImageManager` imports its result handler as a
    /// bare block with no `@Sendable` — so the compiler accepts it and Swift
    /// inserts a dynamic executor check that fires the moment Photos calls it on
    /// `com.apple.photos.requestAVAsset`:
    ///
    /// ```
    /// EXC_BREAKPOINT  thread 9  com.apple.photos.requestAVAsset
    ///   _dispatch_assert_queue_fail
    ///   swift_task_isCurrentExecutorWithFlagsImpl
    ///   closure #1 in closure #1 in PhotosMediaLibrary.videoFile(for:)
    ///   -[PHImageManager requestAVAssetForAsset:options:resultHandler:]_block_invoke_4
    /// ```
    ///
    /// ⚠️ **AND IT IS THE SAME TRAP `DebugPhotoAlbumSeeder.performCreate` WRITES
    /// UP ONE FILE AWAY**, which took `nonisolated` as its cure. The note there
    /// was already exact — "handlers are invoked on an arbitrary serial queue",
    /// same `dispatch_assert_queue_fail` — and this fell into it anyway, because
    /// nothing could reach it: a simulator ships 26 assets and every one is a
    /// still, so until `Scripts/seed-simulator-videos.sh` put real clips in the
    /// device library, no `PHAsset` video had ever been asked for. The unit suite
    /// cannot cover it either — there is no photo library on CI — so the guard is
    /// that script plus a launch into the editor, and this paragraph.
    func videoFile(for item: MediaLibraryItem.ID) async -> URL? {
        guard let asset = assetsByID[item], asset.mediaType == .video else { return nil }

        let options = PHVideoRequestOptions()
        // Same reasoning as a thumbnail's: a clip that lives in iCloud is still
        // one of the viewer's videos, and refusing it would look like a library
        // with holes in it. This is also why the call can take a while — it may
        // be a download.
        options.isNetworkAccessAllowed = true
        // What the viewer sees in Photos, edits included — not the original
        // camera capture. Publishing the unedited take would discard a trim
        // they already made there.
        options.version = .current
        options.deliveryMode = .highQualityFormat

        if let file: URL = await withCheckedContinuation({ continuation in
            let once = ResumeOnce()
            images.requestAVAsset(forVideo: asset, options: options) { @Sendable avAsset, _, _ in
                once.run { continuation.resume(returning: (avAsset as? AVURLAsset)?.url) }
            }
        }) {
            return file
        }

        return await flattened(asset, options: options)
    }

    /// Writes a non-file asset out as one, unchanged.
    ///
    /// `AVAssetExportPresetPassthrough` re-wraps rather than re-encodes: no
    /// quality is spent here, and `VideoExporter` does the real transcode later
    /// on its way to the upload. `.mov` for the same reason — the container is
    /// an intermediate nobody but `VideoExporter` will open.
    private func flattened(_ asset: PHAsset, options: PHVideoRequestOptions) async -> URL? {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("picked-\(UUID().uuidString).mov")

        return await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            images.requestExportSession(
                forVideo: asset, options: options, exportPreset: AVAssetExportPresetPassthrough
            ) { @Sendable session, _ in
                guard let session else {
                    once.run { continuation.resume(returning: nil) }
                    return
                }
                // ⚠️ **`nonisolated(unsafe)` IS THE NARROWEST ESCAPE HATCH HERE,
                // AND IT IS NEEDED BECAUSE `AVAssetExportSession`'s `Sendable`
                // CONFORMANCE IS EXPLICITLY *UNAVAILABLE*** — measured with
                // `-emit-sil`, not inferred. Photos hands the session over on its
                // own queue and never touches it again; this is the single
                // reference, it is used from one `Task` and nowhere else, and it
                // dies with the export. That is the whole argument, and it is
                // written down because the keyword says "unsafe" and cannot say
                // "why".
                nonisolated(unsafe) let held = session
                Task {
                    do {
                        try await held.export(to: output, as: .mov)
                        once.run { continuation.resume(returning: output) }
                    } catch {
                        once.run { continuation.resume(returning: nil) }
                    }
                }
            }
        }
    }

    // MARK: - Caching

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
