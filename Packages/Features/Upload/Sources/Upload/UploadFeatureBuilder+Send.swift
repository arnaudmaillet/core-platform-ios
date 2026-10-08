import AVFoundation
import MediaPlayback
import UIKit

/// A photo or a video picked to SEND in a message, ready for upload (#681).
public enum PickedSendMedia: Sendable {
    /// The picture at publish size, the camera's look and ratio baked in.
    case photo(UIImage)
    /// The clip exported for upload (H.264 in an MP4), with its still.
    case video(ExportedVideo, poster: UIImage?)
}

/// Where the picked media comes from.
public enum SendMediaSource: Sendable {
    case camera
    case library
}

extension UploadFeatureBuilder {
    /// The upload flow's own library sheet or camera, in SEND mode (#681):
    /// what the viewer picks or captures comes back to `completion`, in the
    /// order it was chosen, instead of going on to the editor and a post.
    ///
    /// The caller dismisses the sheet once `completion` has run; "Cancel"
    /// dismisses it without calling it.
    public func makeSendMediaPicker(
        _ source: SendMediaSource,
        completion: @escaping @MainActor ([PickedSendMedia]) -> Void
    ) -> UIViewController {
        let root: UIViewController
        switch source {
        case .library:
            let library = Self.makeSendLibrary()
            root = MediaPickerViewController(library: library, nextTitle: "Send") { chosen in
                Task { @MainActor in
                    completion(await Self.resolve(chosen, edits: [:], library: library))
                }
            }
        case .camera:
            let draft = PostDraft()
            CaptureFolder.sweepOrphans()
            let captures = CapturedMediaLibrary()
            let camera = CaptureViewController(
                source: makeCaptureSource(),
                folder: draft.captureFolder,
                captures: captures,
                libraryFace: nil,
                makeLibraryPicker: nil
            ) { items, edits in
                // The capture's file lives in the draft's folder: resolved
                // (and a clip exported) before the draft can go.
                Task { @MainActor in
                    let picked = await Self.resolve(items, edits: edits, library: captures)
                    withExtendedLifetime(draft) { completion(picked) }
                }
                return nil
            }
            root = camera
        }
        let navigation = UploadNavigationController(rootViewController: root)
        navigation.modalPresentationStyle = .pageSheet
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.selectedDetentIdentifier = .large
            sheet.prefersGrabberVisible = true
        }
        return navigation
    }

    /// The items as they are sent: a photo at publish size with its edits
    /// baked, a clip exported for upload with its still. An item that cannot
    /// be read is skipped.
    static func resolve(
        _ items: [MediaLibraryItem], edits: [String: MediaEdits], library: any MediaLibraryReading
    ) async -> [PickedSendMedia] {
        var picked: [PickedSendMedia] = []
        let exporter = VideoExporter()
        for item in items {
            let edited = edits[item.id] ?? .untouched
            if item.isVideo {
                guard let file = await library.videoFile(for: item.id) else { continue }
                // Against the file's own length, as the post's publish does.
                let length = (try? await AVURLAsset(url: file).load(.duration).seconds) ?? 0
                let plan = edited.exportPlan(
                    sourceURL: file, fileSeconds: length.isFinite ? length : 0, artwork: nil, includingOverlays: true
                )
                guard let exported = try? await exporter.export(plan) else { continue }
                picked.append(.video(exported, poster: await exporter.posterImage(for: exported)))
            } else {
                guard let image = await library.thumbnail(for: item.id, size: sendPixels) else { continue }
                picked.append(.photo(edited.applied(to: image, artwork: nil)))
            }
        }
        return picked
    }

    /// A message's photo is a post's size.
    static let sendPixels = CGSize(width: 1080, height: 1080)

    private static func makeSendLibrary() -> any MediaLibraryReading {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "-upload-fake-library"),
           arguments.count > flag + 1,
           let count = Int(arguments[flag + 1]) {
            return DebugMediaLibrary(count: count)
        }
        #endif
        return PhotosMediaLibrary()
    }
}
