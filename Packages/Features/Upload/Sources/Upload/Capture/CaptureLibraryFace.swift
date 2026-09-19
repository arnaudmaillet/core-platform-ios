import Photos
import Synchronization
import UIKit

/// The newest picture in the device's library — the face of the camera's
/// library shortcut.
///
/// ⚠️ **ONE ASSET, OFF THE MAIN ACTOR.** The shortcut used to ask the picker's
/// library for its albums and then for every item of Recents, to show a 44pt
/// thumbnail of the first: `PhotosMediaLibrary` counts every album and walks
/// every asset — `object(at:)` for each, forty thousand of them in a big
/// library — on the main actor, since the seam is `@MainActor`, just as the
/// sheet presents and the preview starts, and kept every handle for the life of
/// the sheet. This fetches the newest photo or video alone (`fetchLimit` 1,
/// newest first), on a background queue.
///
/// ⚠️ **PHOTOKIT HERE, NOT BEHIND `MediaLibraryReading` — AND WHY.** The seam is
/// where this belongs (a `newestItem()` beside `items(in:)`), but the seam and
/// `PhotosMediaLibrary` are not this change's files. This is the one PhotoKit
/// call the camera makes, it asks nothing of the viewer, and the picker the
/// shortcut opens goes on using the seam.
///
/// ⚠️ **NEVER A PROMPT.** Only the authorisation STATUS is read; with no access
/// there is no face, and the shortcut shows its glyph. The picker asks.
enum CaptureLibraryFace {
    /// The newest photo or video, and nothing else — what the picker's Recents
    /// would show first.
    static var newestFetchOptions: PHFetchOptions {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "mediaType == %d || mediaType == %d",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 1
        return options
    }

    /// The newest picture at `pixels`, or nil without access or without a
    /// picture.
    ///
    /// ⚠️ **THE HANDLER IS FORMED IN HERE, NONISOLATED.** A closure written in a
    /// `@MainActor` type and handed to PhotoKit compiles and traps on its first
    /// callback (`photos-handler-isolation-trap`).
    static func newestPicture(pixels: CGSize) async -> PickedImage? {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let asset = PHAsset.fetchAssets(with: newestFetchOptions).firstObject else {
                    continuation.resume(returning: nil)
                    return
                }
                let options = PHImageRequestOptions()
                // One callback: `.opportunistic` would answer twice, and a
                // continuation resumed twice traps.
                options.deliveryMode = .highQualityFormat
                options.resizeMode = .fast
                // A face is not worth an iCloud download.
                options.isNetworkAccessAllowed = false
                let once = Once()
                PHImageManager.default().requestImage(
                    for: asset, targetSize: pixels, contentMode: .aspectFill, options: options
                ) { @Sendable image, _ in
                    guard once.claim() else { return }
                    continuation.resume(returning: image.map(PickedImage.init))
                }
            }
        }
    }

    /// Lets a callback through once.
    private final class Once: Sendable {
        private let spent = Mutex(false)
        func claim() -> Bool {
            spent.withLock { spent in
                defer { spent = true }
                return !spent
            }
        }
    }
}
