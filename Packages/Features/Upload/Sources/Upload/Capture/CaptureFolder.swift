import Foundation
import Synchronization

/// The directory one camera presentation writes its captures into: the
/// photographs, the clips, and the video a take's clips are stitched into.
///
/// ⚠️ **OWNED BY `PostDraft`, SO IT DIES WITH THE SHEET — `TempFileBag`'S
/// RULE, FOR ITS REASON.** The editor reads these files, the finalisation
/// screen reads them again while "Post" is working, and the sheet is dismissed
/// only once the post is out. A folder deleted by the camera screen when it
/// disappeared would pull a clip out from under the export reading it.
///
/// ⚠️ **ONE DIRECTORY PER PRESENTATION, REMOVED WHOLE.** Every file of the
/// flow is under it, so nothing has to be remembered one by one to be cleaned
/// up; a file the camera throws away early (an undone clip, a slip too short to
/// keep) is removed at once all the same, because a three-minute take is
/// hundreds of megabytes on a phone.
///
/// ⚠️ **NOT THE PHOTO LIBRARY, BY DECISION.** Captures are not saved to Photos;
/// saving belongs to the finalisation screen, where it is being added apart from
/// this.
final class CaptureFolder: Sendable {
    /// Where every presentation's folder is made.
    static var parent: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("UploadCaptures", isDirectory: true)
    }

    /// The names of the folders a live presentation owns — see `sweepOrphans`.
    private static let live = Mutex<Set<String>>([])

    let url: URL

    init(parent: URL = CaptureFolder.parent) {
        let name = UUID().uuidString
        url = parent.appendingPathComponent(name, isDirectory: true)
        Self.live.withLock { _ = $0.insert(name) }
    }

    /// Deletes every folder under `parent` that no live `CaptureFolder` owns.
    ///
    /// ⚠️ **A PROCESS THAT DIES WITH THE SHEET UP NEVER RUNS `deinit`.** Its
    /// captures — a three-minute take is hundreds of megabytes — stayed in the
    /// temporary directory until the system got round to it. The camera sweeps
    /// them when it opens. Owned folders are known by name, registered in
    /// `init` before anything is written, and the directory is listed BEFORE
    /// the owners are read, so a folder made during the sweep is never taken
    /// for an orphan. Off the main thread: it is file deletion.
    static func sweepOrphans(in parent: URL = CaptureFolder.parent, then done: (@Sendable () -> Void)? = nil) {
        DispatchQueue.global(qos: .utility).async {
            let found = (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
            let owned = live.withLock { $0 }
            for entry in found where !owned.contains(entry.lastPathComponent) {
                try? FileManager.default.removeItem(at: entry)
            }
            done?()
        }
    }

    /// A fresh file name in the folder, with `pathExtension`. The folder is made
    /// on first use, so a presentation that captures nothing leaves nothing.
    func newFile(_ prefix: String, pathExtension: String) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.appendingPathComponent("\(prefix)-\(UUID().uuidString)").appendingPathExtension(pathExtension)
    }

    /// Removes one file the flow no longer needs.
    func discard(_ file: URL) {
        guard file.path.hasPrefix(url.path) else { return }
        try? FileManager.default.removeItem(at: file)
    }

    /// Internal for tests: what the folder holds right now.
    var files: [URL] {
        (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
    }

    deinit {
        let name = url.lastPathComponent
        Self.live.withLock { _ = $0.remove(name) }
        try? FileManager.default.removeItem(at: url)
    }
}
