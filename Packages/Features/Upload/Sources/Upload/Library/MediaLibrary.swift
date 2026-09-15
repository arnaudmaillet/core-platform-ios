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

    /// Presents the system sheet that widens a LIMITED selection, hosted by
    /// `host`.
    ///
    /// ⚠️ **IT LIVES BEHIND THIS SEAM FOR THE SAME REASON EVERYTHING ELSE DOES.**
    /// The picker screen has never imported `Photos`, and the one call that would
    /// have made it — `PHPhotoLibrary.shared().presentLimitedLibraryPicker` — is
    /// exactly the sort that quietly drags a framework across a boundary because
    /// it is one line. The stand-in library answers it with nothing, which is how
    /// the simulator path stays honest.
    func presentLimitedPicker(from host: UIViewController)

    /// The albums to offer, in the order the selector shows them: "Recents"
    /// leads. Empty ones are left out — a pill reading "(0)" offers nothing.
    func albums() async -> [MediaLibraryAlbum]

    /// One album's items, newest first.
    func items(in album: MediaLibraryAlbum.ID) async -> [MediaLibraryItem]

    /// A thumbnail at roughly `size` in POINTS, or nil when it could not be
    /// read. Implementations scale by the screen themselves.
    ///
    /// ⚠️ **THE SHAPE IS THE PHOTOGRAPH'S, NOT THE REQUEST'S — AND A CROP DEPENDS
    /// ON IT.** `size` is a bound, not a shape: whatever is returned must wear the
    /// item's own proportions. The editor chooses a crop against a canvas-sized
    /// render (say 402x874) and `NewPostViewController.post()` bakes it against a
    /// 1080x1080 one; `MediaCrop` is fractions, so the two agree only while both
    /// renders share an aspect ratio. An implementation that stretched a picture
    /// to fill the size it was asked for would publish a rectangle nobody chose,
    /// and every test here would still pass. `PhotosMediaLibrary` gets this from
    /// `PHImageContentMode.aspectFit`; `DebugMediaLibrary` derives both sides from
    /// the long edge.
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
