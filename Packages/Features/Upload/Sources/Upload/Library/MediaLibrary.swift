import CoreGraphics
import Foundation
import UIKit

/// What the viewer has let the app see of their library.
enum MediaLibraryAccess: Equatable, Sendable {
    /// Never asked.
    case undetermined
    /// The whole library.
    case granted
    /// Only the assets the viewer picked in the system sheet.
    ///
    /// ⚠️ THIS IS A SUCCESS, NOT AN ERROR. Limited access hands back a real
    /// library that simply holds fewer things, and the grid shows exactly what
    /// it holds. Treating it as a refusal would put an "allow access" wall in
    /// front of photos the viewer has already agreed to share.
    case limited
    /// Refused, or refusable only from Settings.
    case denied
}

/// One entry in the selector at the foot of the picker: "Recents", "Videos", an
/// album the viewer made.
struct MediaLibraryAlbum: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    /// How many items it holds — the number its pill carries beside the title.
    let count: Int
}

/// One item in the grid.
struct MediaLibraryItem: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case photo
        /// Seconds, as the grid stamps them over the thumbnail.
        case video(duration: TimeInterval)
    }

    let id: String
    let kind: Kind

    var isVideo: Bool {
        if case .video = kind { return true }
        return false
    }
}

/// The device's photo library, behind a seam.
///
/// ⚠️ **NEITHER THE TESTS NOR CI HAVE A PHOTO LIBRARY**, and a simulator's is
/// six stock images deep. A screen wired straight into `PHPhotoLibrary` could
/// only ever be tried by hand, against contents nobody controls — so Photos
/// lives behind this, the tests hand the screen a library of their own, and a
/// DEBUG build can be handed a large synthetic one to photograph.
///
/// Every call is `async` because the real one reads from Photos, and `@MainActor`
/// because that is where `PHFetchResult` and its assets are kept here: the
/// fetches are lazy and cheap, and an actor hop per thumbnail would buy nothing
/// a `PHImageManager` request does not already do off the main thread.
@MainActor
protocol MediaLibraryReading: AnyObject {
    /// What the viewer has already allowed, asking them nothing.
    var access: MediaLibraryAccess { get }

    /// Asks, if it has never been asked, and reports what we are left with.
    func requestAccess() async -> MediaLibraryAccess

    /// The albums to offer, in the order the selector shows them: "Recents"
    /// leads. Empty ones are left out — a pill reading "(0)" offers nothing.
    func albums() async -> [MediaLibraryAlbum]

    /// One album's items, newest first.
    func items(in album: MediaLibraryAlbum.ID) async -> [MediaLibraryItem]

    /// A thumbnail at roughly `size` in POINTS, or nil when it could not be
    /// read. Implementations scale by the screen themselves.
    func thumbnail(for item: MediaLibraryItem.ID, size: CGSize) async -> UIImage?

    /// Warms the thumbnails a scroll is about to reach, and lets them go again.
    func startCaching(_ items: [MediaLibraryItem.ID], size: CGSize)
    func stopCaching(_ items: [MediaLibraryItem.ID], size: CGSize)
}

extension MediaLibraryReading {
    /// Caching is an optimisation, so a library that does not have one — every
    /// test double — inherits the two no-ops rather than writing them out.
    func startCaching(_ items: [MediaLibraryItem.ID], size: CGSize) {}
    func stopCaching(_ items: [MediaLibraryItem.ID], size: CGSize) {}
}
