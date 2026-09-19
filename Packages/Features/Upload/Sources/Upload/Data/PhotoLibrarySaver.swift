import Photos
import UIKit

/// One piece of a published post, as it goes into the author's photo library.
///
/// ⚠️ **WHAT WAS PUBLISHED, NOT WHAT WAS CHOSEN.** A photograph is the picture
/// the finalisation screen baked with its crop, look and overlays; a clip is
/// the file the exporter wrote with every edit burned in. Saving the originals
/// would hand the author back what they started from — which, for a capture
/// from the camera, is not even the shape they framed.
enum PhotoLibraryCopy: Equatable, Sendable {
    /// Encoded picture bytes.
    case photo(Data)
    /// A local video file.
    case video(URL)
}

/// Puts copies of a published post's media into the author's photo library.
///
/// ⚠️ **A SEAM, BECAUSE A TEST CANNOT TOUCH THE LIBRARY.** Adding an asset
/// needs a permission prompt nobody can answer in a test host, and a test that
/// did write would leave pictures in the simulator's library for every later
/// run to find.
protocol PhotoLibrarySaving: Sendable {
    /// Asks for add-only access, prompting the first time. True when the
    /// library will take copies.
    func requestAccess() async -> Bool
    /// Adds every copy, in order, in one change: all of them or none.
    func save(_ copies: [PhotoLibraryCopy]) async throws
}

/// The real library.
///
/// ⚠️ **ADD-ONLY ACCESS, AND ITS OWN USAGE STRING.** Saving never needs to
/// READ the library, so it asks for the narrowest permission there is
/// (`NSPhotoLibraryAddUsageDescription`), and an author who gave the picker
/// only a limited selection is not asked to widen it just to keep a copy.
struct PhotoLibrarySaver: PhotoLibrarySaving {
    func requestAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return status == .authorized || status == .limited
    }

    func save(_ copies: [PhotoLibraryCopy]) async throws {
        guard !copies.isEmpty else { return }
        try await Self.add(copies)
    }

    /// ⚠️ **NONISOLATED, AND THE BLOCK `@Sendable`.** Photos runs the change
    /// block on a queue of its own; a block that inherited main-actor
    /// isolation compiles and traps the moment Photos calls it
    /// (`photos-handler-isolation-trap`).
    private nonisolated static func add(_ copies: [PhotoLibraryCopy]) async throws {
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            for copy in copies {
                let request = PHAssetCreationRequest.forAsset()
                switch copy {
                case .photo(let data):
                    request.addResource(with: .photo, data: data, options: nil)
                case .video(let file):
                    request.addResource(with: .video, fileURL: file, options: nil)
                }
            }
        }
    }
}
