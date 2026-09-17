import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// Where "Add a song" can take a song from.
enum MediaSoundtrackOrigin: CaseIterable, Sendable {
    /// A sound file from Files — the author's own music.
    case files
    /// The sound of another video in the library.
    case video
}

/// What a pick came back with.
enum MediaSoundtrackPick: Equatable, Sendable {
    /// An app-owned copy of the chosen sound, and what to call it.
    case picked(fileURL: URL, title: String)
    /// The author closed the picker.
    case cancelled
    /// Something was chosen and could not be copied.
    case failed
}

/// The author's own songs, and nothing else.
///
/// ⚠️ **A SEAM, BECAUSE A TEST CANNOT DRIVE A SYSTEM PICKER.** Both pickers run
/// out of process; what the editor's tests need is the file a pick produces,
/// which a stub can hand over directly. The editor is given one in its `init`.
///
/// ⚠️ **NO CATALOGUE, NO DOWNLOAD.** There is no licensed library of music
/// behind this app, so the songs are ones the author already has: a file, or
/// the sound of a video they shot.
@MainActor
protocol MediaSoundtrackSourcing: AnyObject {
    /// Asks the author for a song from `origin`, putting the picker on screen
    /// with `present`, and answers once they have chosen or closed it.
    func pick(
        from origin: MediaSoundtrackOrigin,
        presenting present: @escaping @MainActor (UIViewController) -> Void
    ) async -> MediaSoundtrackPick
}

/// The real one: the Files picker, and the system's photo picker for videos.
///
/// ⚠️ **NEITHER PICKER COSTS A PERMISSION.** `UIDocumentPickerViewController`
/// hands over a copy of what was chosen, and `PHPickerViewController` runs out
/// of process and needs no library access — built without a photo library, it
/// returns item providers and no asset identifiers, which is all a sound needs.
@MainActor
final class SystemSoundtrackSource: MediaSoundtrackSourcing {
    /// Where the copies are kept, and how long they live.
    let files: TempFileBag

    /// The delegate of the picker on screen — a picker holds its delegate
    /// weakly, so something has to.
    private var pending: AnyObject?

    init(files: TempFileBag = TempFileBag()) {
        self.files = files
    }

    /// What `.files` offers: sound files, and films whose sound can be used.
    static let fileTypes: [UTType] = [.audio, .mpeg4Audio, .mp3, .wav, .aiff, .movie]

    func pick(
        from origin: MediaSoundtrackOrigin,
        presenting present: @escaping @MainActor (UIViewController) -> Void
    ) async -> MediaSoundtrackPick {
        let files = files
        let picked: MediaSoundtrackPick = await withCheckedContinuation { continuation in
            let answer: @Sendable (MediaSoundtrackPick) -> Void = { continuation.resume(returning: $0) }
            let picker: UIViewController
            switch origin {
            case .files:
                let documents = UIDocumentPickerViewController(
                    forOpeningContentTypes: Self.fileTypes, asCopy: true
                )
                documents.allowsMultipleSelection = false
                let delegate = DocumentDelegate(files: files, answer: answer)
                documents.delegate = delegate
                pending = delegate
                picker = documents
            case .video:
                var configuration = PHPickerConfiguration()
                configuration.filter = .videos
                configuration.selectionLimit = 1
                configuration.preferredAssetRepresentationMode = .current
                let videos = PHPickerViewController(configuration: configuration)
                let delegate = VideoDelegate(files: files, answer: answer)
                videos.delegate = delegate
                pending = delegate
                picker = videos
            }
            // ⚠️ A SHEET SWIPED AWAY IS AN ANSWER TOO, or the pick would wait
            // for good and the song tools would stay busy.
            picker.presentationController?.delegate = pending as? UIAdaptivePresentationControllerDelegate
            present(picker)
            // ⚠️ A PRESENTATION UIKIT REFUSED — another one already under way —
            // calls nothing back, ever; the pick ends here instead of waiting.
            if picker.presentingViewController == nil {
                (pending as? OnceDelegate)?.take()?(.cancelled)
            }
        }
        pending = nil
        return picked
    }

    /// Answers once, whichever way the picker ends.
    private class OnceDelegate: NSObject, UIAdaptivePresentationControllerDelegate {
        let files: TempFileBag
        private var answer: (@Sendable (MediaSoundtrackPick) -> Void)?

        init(files: TempFileBag, answer: @escaping @Sendable (MediaSoundtrackPick) -> Void) {
            self.files = files
            self.answer = answer
        }

        /// The answer, the first time it is asked for; nil after.
        func take() -> (@Sendable (MediaSoundtrackPick) -> Void)? {
            defer { answer = nil }
            return answer
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            take()?(.cancelled)
        }
    }

    private final class DocumentDelegate: OnceDelegate, UIDocumentPickerDelegate {
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let answer = take() else { return }
            guard let chosen = urls.first else { return answer(.cancelled) }
            let files = files
            // ⚠️ OFF THE MAIN THREAD: a song is megabytes. The picker's copy is
            // already ours — `asCopy` put it in this app's inbox — and is moved
            // into the bag's folder, then let go.
            Task.detached {
                let copy = files.keepCopy(of: chosen, fallbackExtension: "m4a")
                try? FileManager.default.removeItem(at: chosen)
                answer(copy.map {
                    .picked(fileURL: $0, title: chosen.deletingPathExtension().lastPathComponent)
                } ?? .failed)
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            take()?(.cancelled)
        }
    }

    private final class VideoDelegate: OnceDelegate, PHPickerViewControllerDelegate {
        /// ⚠️ **THE COPY IS MADE INSIDE THE CALLBACK, AND THE CALLBACK IS
        /// `@Sendable`.** `NSItemProvider` calls it on a queue of its own and
        /// deletes the file the moment it returns. A closure written in this
        /// main-actor code without `@Sendable` would inherit the main actor and
        /// trap when called there — the `photos-handler-isolation-trap`, which
        /// compiles cleanly. Only the copy's URL crosses back; the provider, which
        /// is not `Sendable`, never leaves this method.
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let answer = take() else { return }
            guard let provider = results.first?.itemProvider else { return answer(.cancelled) }
            let movie = UTType.movie.identifier
            guard provider.hasItemConformingToTypeIdentifier(movie) else { return answer(.failed) }
            let title = provider.suggestedName.map { "Sound of \($0)" } ?? "Sound of a video"
            let files = files
            _ = provider.loadFileRepresentation(forTypeIdentifier: movie) { @Sendable url, _ in
                let copy = url.flatMap { files.keepCopy(of: $0, fallbackExtension: "mov") }
                answer(copy.map { .picked(fileURL: $0, title: title) } ?? .failed)
            }
        }
    }
}
